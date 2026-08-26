/// On-device Gemma 4 brain (M3).
///
/// Lives in the foreground-service isolate next to BotLink. One long-lived
/// chat, one serialized conversation (BrainSession already enforces that).
/// Native audio in, native function-call tokens out — no STT stage, no
/// regex-parsed tools. Each turn clears history, seeds a short rolling
/// text tail of recent bot replies, then submits the current WAV. Old
/// audio clips are not kept in the token window.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../shared/log.dart';
import '../persona.dart';
import 'bot_brain.dart';
import 'bot_tools.dart';
import 'context_window.dart';
import 'gemma_init.dart';
import 'latency_trace.dart';
import 'model_download.dart';
import 'pcm16.dart';
import 'transcript.dart';

const String _tag = 'GemmaBrain';

/// Context window. 2048 is the documented floor for text; audio + template
/// + decode need headroom. LiteRT fails hard (invoke status 13) when this
/// is too small — it does not degrade.
const int kGemmaMaxTokens = 4096;

/// Cap on generated tokens. A desk robot that monologues is not cute, and
/// decode time is on the latency budget. Kept in lockstep with the persona.
const int kGemmaMaxOutputTokens = kPersonaMaxOutputTokens;

typedef ToolExecutor = Future<Map<String, dynamic>> Function(
    String name, Map<String, dynamic> args);

final class GemmaBrain implements BotBrain {
  GemmaBrain({
    String? modelUrl,
    this.onChanged,
    this.executeTool,
  }) : modelUrl = modelUrl ?? gemmaModelUrlFromEnvironment();

  final String modelUrl;

  /// Fired on download progress and after a turn's latency lands. The
  /// service uses this to push a snapshot; BrainSession already notifies
  /// per token.
  final void Function()? onChanged;

  /// Live tool dispatch (M4). When null, [stubToolResult] is fed back so
  /// unit tests don't need a bot.
  final ToolExecutor? executeTool;

  InferenceModel? _model;
  InferenceChat? _chat;
  bool _warm = false;
  bool _disposed = false;
  String _backend = 'gpu';

  /// 0–100 while the `.litertlm` is downloading; null otherwise.
  int? downloadPercent;

  /// Linear ETA from percent and elapsed. Null until enough samples.
  int? downloadRemainingSec;

  Stopwatch? _downloadEta;

  /// Last completed turn. Warm-up stages are filled on the first turn
  /// after a load (download/load/chatCreate), then left null.
  LatencyTrace? lastLatency;

  int? _warmDownloadMs;
  int? _warmLoadMs;
  int? _warmChatMs;

  Future<void>? _warmUpInFlight;

  String get kind => 'Gemma 4 E2B';

  @override
  Future<void> warmUp() {
    if (_disposed) throw StateError('GemmaBrain used after dispose');
    if (_warm) return Future.value();
    return _warmUpInFlight ??= _warmUp().whenComplete(() {
      _warmUpInFlight = null;
    });
  }

  Future<void> _warmUp() async {
    await ensureGemmaInitialized();

    final downloadWatch = Stopwatch()..start();
    Log.i(_tag, 'installing $modelUrl');
    try {
      await runExclusiveModelInstall(() async {
        // Upgrade cleanup only: stop leftover SmartDownloader workers
        // from older builds. New installs do not enqueue that group.
        await collapseLeftoverModelDownloads();
        if (_disposed) {
          throw StateError('GemmaBrain used after dispose');
        }
        await _installModelFile();
      });
    } on ChunkedDownloadCancelled {
      _clearDownloadProgress();
      onChanged?.call();
      throw StateError('GemmaBrain used after dispose');
    } catch (e) {
      _clearDownloadProgress();
      onChanged?.call();
      rethrow;
    }
    downloadWatch.stop();
    _clearDownloadProgress();
    _warmDownloadMs = downloadWatch.elapsedMilliseconds;
    Log.i(_tag, 'model file ready in ${_warmDownloadMs}ms');
    onChanged?.call();

    if (_disposed) throw StateError('GemmaBrain used after dispose');

    final loadWatch = Stopwatch()..start();
    _model = await _loadModel();
    loadWatch.stop();
    _warmLoadMs = loadWatch.elapsedMilliseconds;
    Log.i(_tag, 'model loaded in ${_warmLoadMs}ms ($_backend)');

    final chatWatch = Stopwatch()..start();
    _chat = await _createChat();
    chatWatch.stop();
    _warmChatMs = chatWatch.elapsedMilliseconds;
    _warm = true;
    Log.i(_tag, 'chat open in ${_warmChatMs}ms');
    onChanged?.call();
  }

  Future<void> _installModelFile() async {
    final dest = File(p.join(
      (await getApplicationDocumentsDirectory()).path,
      modelFilenameFromUrl(modelUrl),
    ));
    if (!localModelLooksComplete(dest)) {
      await waitUntilWifi(isCancelled: () => _disposed);
      if (_disposed) throw const ChunkedDownloadCancelled();
      await downloadModelFile(
        url: modelUrl,
        dest: dest,
        token: downloadTokenForModelUrl(modelUrl),
        onProgress: _onDownloadBytes,
        isCancelled: () => _disposed,
      );
    }
    if (_disposed) throw const ChunkedDownloadCancelled();
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(dest.path).install();
  }

  void _onDownloadBytes(int written, int total) {
    final percent = percentFromBytes(written, total);
    final held = holdDownloadPercent(downloadPercent, percent);
    if (held == downloadPercent && held < 100) return;
    if (held <= 1) {
      (_downloadEta ??= Stopwatch())
        ..reset()
        ..start();
    } else {
      _downloadEta ??= Stopwatch()..start();
    }
    downloadPercent = held;
    downloadRemainingSec = estimateDownloadRemaining(
      percent: held,
      elapsed: _downloadEta!.elapsed,
    )?.inSeconds;
    onChanged?.call();
  }

  Future<InferenceModel> _loadModel() async {
    // Do not pass preferredAudioBackend: gpu. LiteRT-LM's FFI fallback
    // retries the *text* backend only; the audio encoder stays on whatever
    // we set. GPU audio + a GPU OpenCL miss then fails every attempt
    // (gpu-text, then cpu-text) with the misleading "Model may be invalid".
    // The plugin default is CPU for audio — slower encode, actually loads.
    Future<InferenceModel> load(PreferredBackend backend) {
      return FlutterGemma.getActiveModel(
        maxTokens: kGemmaMaxTokens,
        preferredBackend: backend,
        supportAudio: true,
        maxConcurrentSessions: 1,
      );
    }

    try {
      _backend = 'gpu';
      return await load(PreferredBackend.gpu);
    } catch (e, stack) {
      Log.w(_tag, 'GPU load failed, falling back to CPU: $e');
      Log.w(_tag, '$stack');
      try {
        await _model?.close();
      } catch (_) {}
      _model = null;
      _backend = 'cpu';
      return await load(PreferredBackend.cpu);
    }
  }

  Future<InferenceChat> _createChat() async {
    final model = _model;
    if (model == null) {
      throw StateError('createChat before getActiveModel');
    }
    // createChat, not openChat. LiteRT-LM's concurrent openSession path
    // multiplexes by replaying history as text, so it rejects image/audio
    // (`_VirtualConversationHandle._rejectMedia`). Native audio needs the
    // singleton createSession lane. FfiInferenceModel.createChat still
    // forwards `tools` into that session (the base flutter_gemma
    // InferenceModel.createChat does not), so Gemma 4 native
    // `<|tool_call>` routing still engages.
    return model.createChat(
      temperature: 0.8,
      topK: 40,
      topP: 0.95,
      tokenBuffer: 256,
      supportAudio: true,
      supportsFunctionCalls: true,
      tools: kBotTools,
      isThinking: false,
      modelType: ModelType.gemma4,
      toolChoice: ToolChoice.auto,
      systemInstruction: kPersonaSystemInstruction,
      maxOutputTokens: kGemmaMaxOutputTokens,
    );
  }

  @override
  Stream<BrainEvent> respond(AudioClip audio, ConversationContext ctx) async* {
    if (_disposed || !_warm || _chat == null) {
      yield BrainError(_disposed
          ? 'brain used after dispose'
          : 'respond() before warmUp() completed');
      return;
    }

    final totalWatch = Stopwatch()..start();
    try {
      await _resetAndSeed(ctx);

      // WAV, not raw PCM. LiteRT-LM's conversation blob goes through
      // miniaudio, which rejects headerless samples (error -10).
      final wavBytes = pcm16ToWav(audio.pcm, sampleRate: audio.sampleRate);
      Log.i(
        _tag,
        'submit wav ${wavBytes.length} bytes '
        '(${audio.duration.inMilliseconds}ms @ ${audio.sampleRate}Hz)',
      );
      final submitWatch = Stopwatch()..start();
      await _chat!.addQueryChunk(Message.withAudio(
        text: '',
        audioBytes: wavBytes,
        isUser: true,
      ));
      submitWatch.stop();
      yield* _streamAfterSubmit(
        totalWatch: totalWatch,
        submitMs: submitWatch.elapsedMilliseconds,
      );
    } catch (e, stack) {
      Log.e(_tag, 'respond failed', e, stack);
      yield BrainError('$e');
    }
  }

  @override
  Stream<BrainEvent> respondToCue(String cue, ConversationContext ctx) async* {
    if (_disposed || !_warm || _chat == null) {
      yield BrainError(_disposed
          ? 'brain used after dispose'
          : 'respond() before warmUp() completed');
      return;
    }

    final totalWatch = Stopwatch()..start();
    try {
      await _resetAndSeed(ctx);
      Log.i(_tag, 'submit cue "${cue.length > 80 ? '${cue.substring(0, 80)}…' : cue}"');
      final submitWatch = Stopwatch()..start();
      await _chat!.addQueryChunk(Message.text(text: cue, isUser: true));
      submitWatch.stop();
      yield* _streamAfterSubmit(
        totalWatch: totalWatch,
        submitMs: submitWatch.elapsedMilliseconds,
      );
    } catch (e, stack) {
      Log.e(_tag, 'respondToCue failed', e, stack);
      yield BrainError('$e');
    }
  }

  Stream<BrainEvent> _streamAfterSubmit({
    required Stopwatch totalWatch,
    required int submitMs,
  }) async* {
    var firstTokenMs = 0;
    var decodeMs = 0;
    String? firstTokenText;
    Stopwatch? decodeWatch;
    var completed = false;

    await for (final event in _generateTurn()) {
      if (event is TextDelta) {
        if (decodeWatch == null) {
          firstTokenMs = totalWatch.elapsedMilliseconds;
          firstTokenText = event.text;
          decodeWatch = Stopwatch()..start();
        }
      }
      yield event;
      if (event is Done || event is BrainError) {
        completed = event is Done;
        decodeWatch?.stop();
        decodeMs = decodeWatch?.elapsedMilliseconds ?? 0;
        break;
      }
    }

    lastLatency = LatencyTrace(
      downloadMs: _warmDownloadMs,
      modelLoadMs: _warmLoadMs,
      chatCreateMs: _warmChatMs,
      submitMs: submitMs,
      firstTokenMs: firstTokenMs,
      decodeMs: decodeMs,
      totalMs: totalWatch.elapsedMilliseconds,
      backend: _backend,
      firstTokenText: firstTokenText,
    );
    _warmDownloadMs = null;
    _warmLoadMs = null;
    _warmChatMs = null;
    Log.i(_tag, lastLatency!.summary);
    onChanged?.call();
    if (!completed) yield const Done();
  }

  /// One user turn, including the tool-call → tool-response loop. Yields
  /// [ToolCall] the moment the model emits one so the bot can move before
  /// the spoken follow-up starts.
  Stream<BrainEvent> _generateTurn() async* {
    const maxToolTurns = 6;
    for (var turn = 0; turn < maxToolTurns; turn++) {
      final pending = <FunctionCallResponse>[];
      await for (final response in _chat!.generateChatResponseAsync()) {
        switch (response) {
          case TextResponse(:final token):
            if (token.isNotEmpty) yield TextDelta(token);
          case FunctionCallResponse():
            pending.add(response);
            yield ToolCall(
              response.name,
              Map<String, Object?>.from(response.args),
            );
          case ParallelFunctionCallResponse(:final calls):
            for (final call in calls) {
              pending.add(call);
              yield ToolCall(call.name, Map<String, Object?>.from(call.args));
            }
          case ThinkingResponse():
            // isThinking is false; ignore if the model still emits some.
            break;
        }
      }
      if (pending.isEmpty) {
        yield const Done();
        return;
      }
      for (final call in pending) {
        final args = Map<String, dynamic>.from(call.args);
        final result = executeTool != null
            ? await executeTool!(call.name, args)
            : stubToolResult(call.name, args);
        await _chat!.addQueryChunk(Message.toolResponse(
          toolName: call.name,
          response: result,
        ));
      }
    }
    Log.w(_tag, 'hit max tool turns without a final answer');
    yield const Done();
  }

  /// Drop the previous turn's native audio (and Dart history), then seed
  /// the rolling bot-text window. Called at the start of each [respond],
  /// never mid tool-call loop.
  ///
  /// Path: [InferenceChat.clearHistory] (flutter_gemma 1.6.3). That closes
  /// the LiteRT-LM conversation and [createSession]s a fresh one via the
  /// chat's `sessionCreator` — same tools, systemInstruction, supportAudio.
  /// The model stays loaded; we do not [createChat] per turn.
  Future<void> _resetAndSeed(ConversationContext ctx) async {
    final prior = rollingTextWindow(ctx.transcript);
    await _chat!.clearHistory();
    Log.i(_tag, 'cleared history, seeded ${prior.length} text lines');
    for (final entry in prior) {
      await _chat!.addQueryChunk(Message.text(
        text: entry.text,
        isUser: entry.role == TranscriptRole.user,
      ));
    }
  }

  void _clearDownloadProgress() {
    downloadPercent = null;
    downloadRemainingSec = null;
    _downloadEta?.stop();
    _downloadEta = null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _warm = false;
    _clearDownloadProgress();
    try {
      await _chat?.close();
    } catch (e) {
      Log.w(_tag, 'chat close failed: $e');
    }
    _chat = null;
    try {
      await _model?.close();
    } catch (e) {
      Log.w(_tag, 'model close failed: $e');
    }
    _model = null;
  }
}
