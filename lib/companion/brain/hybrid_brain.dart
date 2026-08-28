/// NLP fast path in front of a [BotBrain] (Gemma or fake).
///
/// Hits skip the model: timer cues, formulaic spoken commands once ASR
/// returns text, and the persona few-shots. Misses fall through to [inner]
/// unchanged — native audio Gemma stays the open-ended path.
library;

import '../../shared/log.dart';
import 'bot_brain.dart';
import 'clip_asr.dart';
import 'fast_intent.dart';
import 'gemma_brain.dart';
import 'latency_trace.dart';

const String _tag = 'HybridBrain';

final class HybridBrain implements BotBrain {
  HybridBrain({
    required this.inner,
    this.executeTool,
    this.asr,
    this.onHeard,
    this.onRoute,
  });

  final BotBrain inner;

  /// Live dispatch on NLP hits, same contract as [GemmaBrain.executeTool].
  /// Null when the session's `onToolCall` is the dispatcher (FakeBrain).
  final ToolExecutor? executeTool;

  /// Optional PCM → text sidecar. Null = spoken turns always go to [inner].
  final ClipAsr? asr;

  /// Fired with the ASR transcript (debug panel / activity log).
  final void Function(String text)? onHeard;

  /// Fired after the matcher: [fastIntent] is true when the LLM was skipped.
  final void Function({
    required bool fastIntent,
    String? text,
    String? reason,
  })? onRoute;

  /// Last ASR transcript, if any. Not a cue.
  String? lastHeardText;

  /// Last completed turn. NLP hits use `backend: nlp`; LLM misses copy
  /// Gemma's trace when [inner] is a [GemmaBrain].
  LatencyTrace? lastLatency;

  @override
  Future<void> warmUp() async {
    await Future.wait([
      inner.warmUp(),
      if (asr != null) asr!.warmUp(),
    ]);
  }

  @override
  Stream<BrainEvent> respond(AudioClip audio, ConversationContext ctx) async* {
    final watch = Stopwatch()..start();
    lastHeardText = null;
    final text = await asr?.transcribe(audio);
    if (text != null && text.isNotEmpty) {
      lastHeardText = text;
      onHeard?.call(text);
      final hit = matchText(text);
      if (hit != null) {
        yield* _emitHit(hit, watch, heard: text);
        return;
      }
      _logRoute(fastIntent: false, text: text);
    } else {
      _logRoute(fastIntent: false);
    }
    yield* _forward(inner.respond(audio, ctx));
  }

  @override
  Stream<BrainEvent> respondToCue(String cue, ConversationContext ctx) async* {
    final watch = Stopwatch()..start();
    final hit = matchText(cue);
    if (hit != null) {
      yield* _emitHit(hit, watch, heard: cue);
      return;
    }
    _logRoute(fastIntent: false, text: cue);
    yield* _forward(inner.respondToCue(cue, ctx));
  }

  Stream<BrainEvent> _emitHit(
    FastIntentHit hit,
    Stopwatch watch, {
    required String heard,
  }) async* {
    _logRoute(fastIntent: true, text: heard, reason: hit.reason);
    Log.i(_tag, 'Fast intent tools: '
        '${hit.calls.map((c) => c.transcriptLine).join('; ')}');
    final extra = <ToolCall>[];
    for (final call in hit.calls) {
      yield call;
      if (executeTool == null) continue;
      final args = Map<String, dynamic>.from(call.arguments);
      final result = await executeTool!(call.name, args);
      if (call.name == 'get_battery' &&
          !hit.calls.any((c) => c.name == 'express')) {
        extra.add(ToolCall('express', {
          'mood': moodFromBatteryPercent(result['percent']).name,
        }));
      }
    }
    for (final call in extra) {
      yield call;
      if (executeTool != null) {
        await executeTool!(
          call.name,
          Map<String, dynamic>.from(call.arguments),
        );
      }
    }
    watch.stop();
    final first = [...hit.calls, ...extra].first;
    lastLatency = LatencyTrace(
      submitMs: 0,
      firstTokenMs: watch.elapsedMilliseconds,
      decodeMs: 0,
      totalMs: watch.elapsedMilliseconds,
      backend: 'nlp',
      firstTokenText: first.transcriptLine,
    );
    Log.i(_tag, lastLatency!.summary);
    yield const Done();
  }

  Stream<BrainEvent> _forward(Stream<BrainEvent> events) async* {
    yield* events;
    final model = inner;
    if (model is GemmaBrain) lastLatency = model.lastLatency;
  }

  @override
  Future<void> dispose() async {
    await asr?.dispose();
    await inner.dispose();
  }

  void _logRoute({
    required bool fastIntent,
    String? text,
    String? reason,
  }) {
    final heard = (text != null && text.isNotEmpty)
        ? '"${_preview(text)}"'
        : '(no transcript)';
    if (fastIntent) {
      Log.i(_tag, 'Fast intent (${reason ?? '?'}): $heard');
    } else {
      Log.i(_tag, 'LLM: $heard');
    }
    onRoute?.call(fastIntent: fastIntent, text: text, reason: reason);
  }

  static String _preview(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 80) return flat;
    return '${flat.substring(0, 80)}…';
  }
}
