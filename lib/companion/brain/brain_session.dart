/// Owns one [BotBrain] plus the durable transcript, and serializes every
/// consumer into a single conversation queue (M2).
///
/// The serialization is a hard rule from the runtime (M3): LiteRT-LM allows
/// one Conversation per Engine, so chat turns, tool follow-ups and (later,
/// M4) timer announcements must never race — they enter this queue and run
/// strictly one at a time. Building the queue now, while the brain is fake,
/// means M3 drops into an already-correct structure.
///
/// Recovery lifecycle (kill → restart → re-warm is *normal*, not an error):
/// [start] loads the persisted transcript, re-warms the brain, and the
/// transcript is replayed as context on the next respond — a fresh session
/// paying a full prefill, which is exactly what the real model will cost.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../shared/log.dart';
import 'bot_brain.dart';
import 'transcript.dart';

const String _tag = 'BrainSession';

enum BrainSessionState {
  /// No brain loaded (before [start], or after a failed warm-up).
  cold,

  /// Model loading / transcript replaying. Tens of seconds is normal.
  warming,

  /// Warm and idle: ready for an utterance.
  ready,

  /// An utterance is arriving, queued, or being prefilled.
  thinking,

  /// Response text is streaming.
  responding,
}

final class BrainSession extends ChangeNotifier {
  BrainSession({
    required BotBrain brain,
    required TranscriptStore transcript,
    this.onToolCall,
  })  : _brain = brain,
        _transcript = transcript;

  final BotBrain _brain;
  final TranscriptStore _transcript;

  /// Structured tool calls surface here so FakeBrain (which has no live
  /// executor) can still move the bot. GemmaBrain dispatches inside the
  /// generate loop via its executeTool callback so the body moves before
  /// the turn ends. The compact tool line is also the transcript entry.
  final void Function(ToolCall call)? onToolCall;

  BrainSessionState state = BrainSessionState.cold;
  String? lastError;

  /// Transcript entries recovered from storage at [start] — the visible
  /// proof that persistence survived the kill.
  int replayedEntries = 0;

  /// Response text accumulated so far for the in-flight turn. Mute path:
  /// this is the compact tool line (`express(delighted)`), not speech.
  String responseText = '';

  /// Full text of the last completed turn.
  String lastResponseText = '';

  /// Utterances dropped because the brain was not ready (still warming, or
  /// warm-up failed).
  int droppedUtterances = 0;

  List<TranscriptEntry> get transcript => _transcript.entries;

  /// The serialized conversation queue. Every consumer chains onto this;
  /// nothing runs concurrently against the brain.
  Future<void> _queue = Future.value();
  bool _disposed = false;
  bool _turnInFlight = false;

  /// Loads the transcript and warms the brain. Safe to call again after a
  /// failed warm-up (retry path); a no-op when already warm.
  Future<void> start() async {
    if (state != BrainSessionState.cold) return;
    state = BrainSessionState.warming;
    lastError = null;
    notifyListeners();

    try {
      final recovered = await _transcript.load();
      replayedEntries = recovered.length;
      Log.i(_tag, 'replaying ${recovered.length} transcript entries');
      await _brain.warmUp();
      state = BrainSessionState.ready;
      Log.i(_tag, 'brain warm');
    } catch (e, stack) {
      // Model OOM / load failure path: stay cold, keep the error visible,
      // allow retry. The transcript is untouched.
      lastError = 'warm-up failed: $e';
      state = BrainSessionState.cold;
      Log.e(_tag, 'warm-up failed', e, stack);
    }
    notifyListeners();
  }

  /// First audio frame of a live utterance. Flips [ready] → [thinking] so
  /// the UI and bot LEDs move while frames are still arriving. No-op if a
  /// turn is already in flight or the brain is not idle.
  void noteIncomingAudio() {
    if (_disposed) return;
    if (state != BrainSessionState.ready) return;
    state = BrainSessionState.thinking;
    notifyListeners();
  }

  /// Reverts [noteIncomingAudio] when the clip finalized empty (lost all
  /// samples, or an end-only frame) and no turn was queued.
  void cancelListening() {
    if (_disposed) return;
    if (state != BrainSessionState.thinking || _turnInFlight) return;
    state = BrainSessionState.ready;
    notifyListeners();
  }

  /// Queues one utterance for a response. Returns when the turn finishes
  /// (or is dropped). Concurrent callers are serialized, never rejected.
  Future<void> handleUtterance(AudioClip clip) {
    if (_disposed) return Future.value();
    if (state == BrainSessionState.cold ||
        state == BrainSessionState.warming) {
      droppedUtterances += 1;
      Log.w(_tag,
          'dropping utterance (${clip.duration.inMilliseconds} ms): brain ${state.name}');
      notifyListeners();
      return Future.value();
    }
    final turn = _queue.then((_) => _runTurn(clip));
    // Keep the queue alive whatever a turn does; _runTurn already reports.
    _queue = turn.catchError((_) {});
    return turn;
  }

  /// Queues a non-audio cue (timer fire) on the same conversation queue
  /// as spoken turns. Never races the chat.
  Future<void> handleCue(String cue) {
    if (_disposed) return Future.value();
    if (state == BrainSessionState.cold ||
        state == BrainSessionState.warming) {
      droppedUtterances += 1;
      Log.w(_tag, 'dropping cue: brain ${state.name}');
      notifyListeners();
      return Future.value();
    }
    final turn = _queue.then((_) => _runCue(cue));
    _queue = turn.catchError((_) {});
    return turn;
  }

  Future<void> _runTurn(AudioClip clip) async {
    if (_disposed) return;

    _turnInFlight = true;
    state = BrainSessionState.thinking;
    responseText = '';
    notifyListeners();

    final seconds = (clip.duration.inMilliseconds / 1000).toStringAsFixed(1);
    await _transcript.append(TranscriptEntry(
      role: TranscriptRole.user,
      text: '(voice, $seconds s)',
    ));

    final ctx = ConversationContext(transcript: _transcript.entries);
    var completed = false;

    try {
      await for (final event in _brain.respond(clip, ctx)) {
        if (_disposed) return;
        switch (event) {
          case TextDelta(:final text):
            if (state != BrainSessionState.responding) {
              state = BrainSessionState.responding;
            }
            responseText += text;
            notifyListeners();
          case ToolCall():
            Log.i(_tag, 'tool call: $event');
            if (state != BrainSessionState.responding) {
              state = BrainSessionState.responding;
            }
            if (responseText.isNotEmpty) responseText += '; ';
            responseText += event.transcriptLine;
            notifyListeners();
            onToolCall?.call(event);
          case Done():
            completed = true;
          case BrainError(:final message):
            lastError = message;
            Log.e(_tag, 'brain error: $message');
        }
      }
    } catch (e, stack) {
      lastError = 'respond failed: $e';
      Log.e(_tag, 'respond stream failed', e, stack);
    } finally {
      if (completed && responseText.isNotEmpty && !_disposed) {
        lastResponseText = responseText;
        await _transcript.append(TranscriptEntry(
          role: TranscriptRole.bot,
          text: responseText,
        ));
      }
      responseText = '';
      _turnInFlight = false;
      if (!_disposed) {
        state = BrainSessionState.ready;
        notifyListeners();
      }
    }
  }

  Future<void> _runCue(String cue) async {
    if (_disposed) return;

    _turnInFlight = true;
    state = BrainSessionState.thinking;
    responseText = '';
    notifyListeners();

    await _transcript.append(TranscriptEntry(
      role: TranscriptRole.system,
      text: '(timer fired)',
    ));

    final ctx = ConversationContext(transcript: _transcript.entries);
    var completed = false;

    try {
      await for (final event in _brain.respondToCue(cue, ctx)) {
        if (_disposed) return;
        switch (event) {
          case TextDelta(:final text):
            if (state != BrainSessionState.responding) {
              state = BrainSessionState.responding;
            }
            responseText += text;
            notifyListeners();
          case ToolCall():
            Log.i(_tag, 'tool call: $event');
            if (state != BrainSessionState.responding) {
              state = BrainSessionState.responding;
            }
            if (responseText.isNotEmpty) responseText += '; ';
            responseText += event.transcriptLine;
            notifyListeners();
            onToolCall?.call(event);
          case Done():
            completed = true;
          case BrainError(:final message):
            lastError = message;
            Log.e(_tag, 'brain error: $message');
        }
      }
    } catch (e, stack) {
      lastError = 'cue failed: $e';
      Log.e(_tag, 'cue stream failed', e, stack);
    } finally {
      if (completed && responseText.isNotEmpty && !_disposed) {
        lastResponseText = responseText;
        await _transcript.append(TranscriptEntry(
          role: TranscriptRole.bot,
          text: responseText,
        ));
      }
      responseText = '';
      _turnInFlight = false;
      if (!_disposed) {
        state = BrainSessionState.ready;
        notifyListeners();
      }
    }
  }

  Future<void> clearTranscript() async {
    await _transcript.clear();
    replayedEntries = 0;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_brain.dispose());
    super.dispose();
  }
}
