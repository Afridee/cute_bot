/// Canned-response brain (M2). Lets M1/M2 be built and tested without the
/// model: realistic delays, streaming text deltas, occasional tool calls —
/// the same event shapes GemmaBrain (M3) will produce.
///
/// Delays are injectable so unit tests run at Duration.zero.
library;

import 'dart:async';

import 'bot_brain.dart';

final class FakeBrain implements BotBrain {
  FakeBrain({
    this.warmUpDelay = const Duration(seconds: 4),
    this.thinkDelay = const Duration(milliseconds: 600),
    this.tokenDelay = const Duration(milliseconds: 40),
    this.prefillDelayPerEntry = const Duration(milliseconds: 30),
  });

  /// Stands in for model load. A real E2B/E4B warm-up is tens of seconds;
  /// a few seconds is enough to make the warming state visible on the bot.
  final Duration warmUpDelay;

  /// Stands in for prefill + first token.
  final Duration thinkDelay;

  /// Stands in for per-token decode.
  final Duration tokenDelay;

  /// Stands in for re-prefill cost. FakeBrain sees the full transcript
  /// (including user voice stubs); GemmaBrain seeds a rolling bot-text
  /// window instead. Fine for tests. Applied per context entry on respond.
  final Duration prefillDelayPerEntry;

  bool _warm = false;
  bool _disposed = false;
  int _responseCounter = 0;
  Future<void>? _warmUpInFlight;

  /// How many times the delay body ran. Overlapping [warmUp] calls share one.
  int warmUpRuns = 0;

  static final List<String Function(AudioClip clip)> _responses = [
    (clip) {
      final secs = (clip.duration.inMilliseconds / 1000).toStringAsFixed(1);
      return 'Ooh, I heard you talk for $secs seconds! Tell me more?';
    },
    (_) => 'Beep! I am just a little desk robot, but I am listening.',
    (_) => 'That sounds exciting! My LEDs are tingling.',
    (_) => 'I will remember that. Well... after M3 I will.',
    (_) => 'Wiggle wiggle! Sorry, I got carried away.',
  ];

  @override
  Future<void> warmUp() {
    if (_disposed) throw StateError('FakeBrain used after dispose');
    if (_warm) return Future.value();
    return _warmUpInFlight ??= _doWarmUp().whenComplete(() {
      _warmUpInFlight = null;
    });
  }

  Future<void> _doWarmUp() async {
    warmUpRuns += 1;
    await Future<void>.delayed(warmUpDelay);
    if (!_disposed) _warm = true;
  }

  @override
  Stream<BrainEvent> respond(AudioClip audio, ConversationContext ctx) async* {
    if (_disposed || !_warm) {
      yield BrainError(_disposed
          ? 'brain used after dispose'
          : 'respond() before warmUp() completed');
      return;
    }

    // Prefill simulation: context costs time, like a real replay would.
    await Future<void>.delayed(
        thinkDelay + prefillDelayPerEntry * ctx.transcript.length);

    final index = _responseCounter++;

    // Every third response exercises the tool-call path (shape of M4).
    if (index % 3 == 0) {
      yield const ToolCall(
          'set_led', {'color': 'pink', 'pattern': 'blink'});
    }

    final words = _responses[index % _responses.length](audio).split(' ');
    for (var i = 0; i < words.length; i++) {
      await Future<void>.delayed(tokenDelay);
      yield TextDelta(i == 0 ? words[i] : ' ${words[i]}');
    }
    yield const Done();
  }

  @override
  Stream<BrainEvent> respondToCue(String cue, ConversationContext ctx) async* {
    if (_disposed || !_warm) {
      yield BrainError(_disposed
          ? 'brain used after dispose'
          : 'respond() before warmUp() completed');
      return;
    }
    await Future<void>.delayed(thinkDelay);
    yield const ToolCall('set_led', {'color': 'yellow', 'pattern': 'blink'});
    final words = _cueReply(cue).split(' ');
    for (var i = 0; i < words.length; i++) {
      await Future<void>.delayed(tokenDelay);
      yield TextDelta(i == 0 ? words[i] : ' ${words[i]}');
    }
    yield const Done();
  }

  static String _cueReply(String cue) {
    final match = RegExp(r"timer[^:]*:\s*'([^']+)'").firstMatch(cue);
    final label = match?.group(1);
    if (label != null && label.isNotEmpty) {
      return 'Time\'s up for $label!';
    }
    return 'Time\'s up!';
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _warm = false;
  }
}
