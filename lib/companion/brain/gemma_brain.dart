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

import 'package:flutter_gemma/flutter_gemma.dart';

import '../../shared/log.dart';
import 'bot_brain.dart';
import 'bot_tools.dart';
import 'context_window.dart';
import 'gemma_init.dart';
import 'latency_trace.dart';
import 'pcm16.dart';
import 'transcript.dart';

const String _tag = 'GemmaBrain';

/// Default E2B bundle. Latency over intelligence; E4B is a drop-in URL swap.
const String kGemma4E2BUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

/// Context window. 2048 is the documented floor for text; audio + template
/// + decode need headroom. LiteRT fails hard (invoke status 13) when this
/// is too small — it does not degrade.
const int kGemmaMaxTokens = 4096;

/// Cap on generated tokens. A desk robot that monologues is not cute, and
/// decode time is on the latency budget. M5 will tune this with the persona.
const int kGemmaMaxOutputTokens = 80;

/// Temporary system prompt. M5 moves this to `lib/companion/persona.dart`.
const String kGemmaSystemInstruction =
    'You are a tiny desk robot. You hear the user through your microphone. '
    'Reply in one or two short spoken sentences — no markdown, no lists, '
    'no stage directions. When a feeling fits, call a tool to show it on '
    'your LEDs or body, then say the words.';

final class GemmaBrain implements BotBrain {
  GemmaBrain({
    this.modelUrl = kGemma4E2BUrl,
    this.onChanged,
  });

  final String modelUrl;

  /// Fired on download progress and after a turn's latency lands. The
  /// service uses this to push a snapshot; BrainSession already notifies
  /// per token.
  final void Function()? onChanged;

  InferenceModel? _model;
  InferenceChat? _chat;
  bool _warm = false;
  bool _disposed = false;
  String _backend = 'gpu';

  /// 0–100 while the `.litertlm` is downloading; null otherwise.
  int? downloadPercent;

  /// Last completed turn. Warm-up stages are filled on the first turn
  /// after a load (download/load/chatCreate), then left null.
  LatencyTrace? lastLatency;

  int? _warmDownloadMs;
  int? _warmLoadMs;
  int? _warmChatMs;

  String get kind => 'Gemma 4 E2B';

  @override
  Future<void> warmUp() async {
    if (_disposed) throw StateError('GemmaBrain used after dispose');
    if (_warm) return;

    await ensureGemmaInitialized();

    final downloadWatch = Stopwatch()..start();
    Log.i(_tag, 'installing $modelUrl');
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    )
        .fromNetwork(
          modelUrl,
          token: huggingFaceTokenFromEnvironment(),
          // Already running inside our connectedDevice FGS; don't start a
          // second one with a different type.
          foreground: false,
        )
        .withProgress((percent) {
          downloadPercent = percent;
          onChanged?.call();
        })
        .install();
    downloadWatch.stop();
    downloadPercent = null;
    _warmDownloadMs = downloadWatch.elapsedMilliseconds;
    Log.i(_tag, 'model file ready in ${_warmDownloadMs}ms');
    onChanged?.call();

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
      systemInstruction: kGemmaSystemInstruction,
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
      final submitMs = submitWatch.elapsedMilliseconds;

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
      // Warm-up stages are one-shot; later turns shouldn't keep reprinting
      // a minutes-long download.
      _warmDownloadMs = null;
      _warmLoadMs = null;
      _warmChatMs = null;
      Log.i(_tag, lastLatency!.summary);
      onChanged?.call();
      if (!completed) yield const Done();
    } catch (e, stack) {
      Log.e(_tag, 'respond failed', e, stack);
      yield BrainError('$e');
    }
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
        await _chat!.addQueryChunk(Message.toolResponse(
          toolName: call.name,
          response: stubToolResult(call.name, call.args),
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

  @override
  Future<void> dispose() async {
    _disposed = true;
    _warm = false;
    downloadPercent = null;
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
