/// Sentence-by-sentence TTS over BLE (M5).
///
/// Accumulates [TextDelta] text, synthesizes completed sentences as they
/// land, and writes one BLE utterance (start → frames → end) so the bot
/// can mute its mic for the whole reply (half-duplex).
library;

import 'dart:async';

import '../../shared/audio_transport.dart';
import '../../shared/ble_protocol.dart';
import '../../shared/log.dart';
import 'sentences.dart';
import 'voice.dart';

const String _tag = 'ReplySpeaker';

/// How many in-flight audio frames before we pause the send loop. Keeps
/// the write queue from dropping oldest (speech would skip).
const int kSpeechQueueHighWater = 24;

final class ReplySpeaker {
  ReplySpeaker({
    required this.voice,
    required this.sendFrame,
    required this.mtu,
    required this.queuedFrames,
    this.onSpeakingChanged,
  });

  final Voice voice;
  final void Function(AudioChunkMessage frame) sendFrame;
  final int Function() mtu;
  final int Function() queuedFrames;
  final void Function(bool speaking)? onSpeakingChanged;

  bool get speaking => _speaking;

  /// First BLE audio frame of this reply, elapsed from [beginTurn].
  int? firstAudioMs;

  String _pending = '';
  String _emittedPrefix = '';
  bool _speaking = false;
  bool _turnOpen = false;
  bool _finalPending = false;
  UtteranceChunker? _chunker;
  Stopwatch? _turnWatch;
  Future<void> _queue = Future.value();

  /// Call when a new brain turn starts (thinking), before deltas arrive.
  /// Queued behind any in-flight speak so two replies never interleave.
  Future<void> beginTurn() {
    final op = _queue.then((_) {
      _pending = '';
      _emittedPrefix = '';
      _finalPending = false;
      firstAudioMs = null;
      _turnWatch = Stopwatch()..start();
    });
    _queue = op.catchError((_) {});
    return op;
  }

  /// [fullText] is the accumulated reply so far. [isFinal] flushes the
  /// remainder and ends the BLE utterance.
  Future<void> update(String fullText, {required bool isFinal}) {
    final op = _queue.then((_) => _apply(fullText, isFinal: isFinal));
    _queue = op.catchError((_) {});
    return op;
  }

  Future<void> get idle => _queue;

  Future<void> _apply(String fullText, {required bool isFinal}) async {
    if (fullText.startsWith(_emittedPrefix)) {
      _pending += fullText.substring(_emittedPrefix.length);
    } else {
      _pending = fullText;
    }
    _emittedPrefix = fullText;
    if (isFinal) _finalPending = true;
    await _pump();
  }

  Future<void> _pump() async {
    try {
      while (true) {
        final flush = _finalPending;
        final split = takeSentences(_pending, flush: flush);
        _pending = split.$2;
        if (split.$1.isEmpty) {
          if (flush) {
            await _endUtterance();
            _finalPending = false;
          }
          return;
        }
        for (final sentence in split.$1) {
          await _speakSentence(sentence);
        }
      }
    } catch (e, stack) {
      Log.e(_tag, 'speak failed', e, stack);
      await _endUtterance();
      _finalPending = false;
    }
  }

  Future<void> _speakSentence(String sentence) async {
    final pcm = await voice.synthesize(sentence);
    if (pcm.isEmpty) return;
    _ensureUtterance();
    final chunker = _chunker!;
    for (final frame in chunker.addSamples(pcm)) {
      await _send(frame);
    }
  }

  void _ensureUtterance() {
    if (_turnOpen) return;
    _chunker = UtteranceChunker(mtu: mtu());
    _turnOpen = true;
    _setSpeaking(true);
  }

  Future<void> _endUtterance() async {
    if (!_turnOpen) {
      _setSpeaking(false);
      return;
    }
    final chunker = _chunker;
    _chunker = null;
    _turnOpen = false;
    if (chunker != null) {
      for (final frame in chunker.finish()) {
        await _send(frame);
      }
    }
    var spins = 0;
    while (queuedFrames() > 0 && spins < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      spins++;
    }
    _setSpeaking(false);
  }

  Future<void> _send(AudioChunkMessage frame) async {
    if (firstAudioMs == null && frame.adpcmBlock.isNotEmpty) {
      firstAudioMs = _turnWatch?.elapsedMilliseconds;
      Log.i(_tag, 'first audio ${firstAudioMs}ms');
    }
    sendFrame(frame);
    while (queuedFrames() > kSpeechQueueHighWater) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void _setSpeaking(bool value) {
    if (_speaking == value) return;
    _speaking = value;
    onSpeakingChanged?.call(value);
  }
}
