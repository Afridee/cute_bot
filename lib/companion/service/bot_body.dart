/// Phone-side tool dispatch (M4).
///
/// Maps Gemma tool names onto BLE control writes, the phone timer store,
/// and battery telemetry. The same writes hit the simulator or a real
/// ESP32; firmware no-ops `wiggle` if there is no servo.
library;

import 'dart:async';

import '../../shared/ble_protocol.dart';
import '../../shared/log.dart';
import '../expressions.dart';
import 'timer_store.dart';

const String _tag = 'BotBody';

/// Result of [BotBody.invoke]. [result] is what the model sees as the
/// tool response. Timer fields tell [BotService] how to keep Dart
/// timers and the OLED countdown in lockstep with the store.
final class ToolInvokeResult {
  const ToolInvokeResult(
    this.result, {
    this.armed,
    this.cancelledId,
    this.paused,
    this.resumed,
  });

  final Map<String, dynamic> result;

  /// Newly armed timer, if this was a successful `set_timer`.
  final PendingTimer? armed;

  /// Id of a timer just dropped by `cancel_timer`, or replaced by
  /// `set_timer`. BotService must cancel that Dart [Timer] so it cannot fire.
  final String? cancelledId;

  /// Timer after a successful `pause_timer` (Dart clock should stop).
  final PendingTimer? paused;

  /// Timer after a successful `resume_timer` (Dart clock should arm).
  final PendingTimer? resumed;
}

final class BotBody {
  BotBody({
    required this.timers,
    required this.sendControl,
    required this.nextSequence,
    required this.waitForBattery,
    this.now = DateTime.now,
    this.maxMinutes = 180,
  });

  final TimerStore timers;
  final void Function(ControlMessage message, String label, {bool quiet})
      sendControl;
  final int Function() nextSequence;
  final Future<({int percent, int millivolts, bool charging})?> Function()
      waitForBattery;
  final DateTime Function() now;
  final int maxMinutes;

  Future<ToolInvokeResult> invoke(
      String name, Map<String, Object?> args) async {
    switch (name) {
      case 'express':
        return _express(args);
      case 'set_led':
        final rgb = ledColor(args['color']);
        sendControl(
          SetLedCommand(
            sequence: nextSequence(),
            red: rgb.$1,
            green: rgb.$2,
            blue: rgb.$3,
            pattern: ledPattern(args['pattern']),
          ),
          'tool set_led',
        );
        return ToolInvokeResult({
          'status': 'ok',
          'color': args['color'],
          'pattern': args['pattern'],
        });
      case 'wiggle':
        sendControl(WiggleCommand(sequence: nextSequence()), 'tool wiggle');
        return const ToolInvokeResult({'status': 'ok'});
      case 'play_sound':
        sendControl(
          PlaySoundCommand(
              sequence: nextSequence(), sound: botSound(args['name'])),
          'tool play_sound',
        );
        return ToolInvokeResult({'status': 'ok', 'name': args['name']});
      case 'get_battery':
        sendControl(
          GetBatteryCommand(sequence: nextSequence()),
          'tool get_battery',
        );
        final battery = await waitForBattery();
        if (battery == null) {
          return const ToolInvokeResult({
            'status': 'unknown',
            'note': 'bot did not report battery',
          });
        }
        return ToolInvokeResult({
          'status': 'ok',
          'percent': battery.percent,
          'millivolts': battery.millivolts,
          'charging': battery.charging,
        });
      case 'set_timer':
        return _setTimer(args);
      case 'cancel_timer':
        return _cancelTimer(args);
      case 'pause_timer':
        return _pauseTimer(args);
      case 'resume_timer':
        return _resumeTimer(args);
      default:
        Log.w(_tag, 'unhandled tool: $name');
        return ToolInvokeResult({'error': 'unknown tool $name'});
    }
  }

  /// Actuates one catalog mood on the bot (LED + optional sound / wiggle).
  /// Used by `express` tools and phone-side lifecycle states (thinking, warming).
  void showMood(BotMood mood, {String labelPrefix = 'mood', bool quiet = false}) {
    final spec = kExpressions[mood];
    if (spec == null) return;
    final rgb = ledColor(spec.color);
    sendControl(
      SetLedCommand(
        sequence: nextSequence(),
        red: rgb.$1,
        green: rgb.$2,
        blue: rgb.$3,
        pattern: ledPattern(spec.pattern),
      ),
      '$labelPrefix ${spec.mood.name}',
      quiet: quiet,
    );
    if (spec.sound != null) {
      sendControl(
        PlaySoundCommand(
            sequence: nextSequence(), sound: botSound(spec.sound)),
        '$labelPrefix sound',
        quiet: quiet,
      );
    }
    if (spec.wiggle) {
      sendControl(
          WiggleCommand(sequence: nextSequence()), '$labelPrefix wiggle',
          quiet: quiet);
    }
  }

  Future<ToolInvokeResult> _express(Map<String, Object?> args) async {
    final spec = expressionFor(args['mood']);
    if (spec == null) {
      return ToolInvokeResult({'error': 'unknown mood ${args['mood']}'});
    }
    showMood(spec.mood, labelPrefix: 'tool express');
    return ToolInvokeResult({
      'status': 'ok',
      'mood': spec.mood.name,
    });
  }

  Future<ToolInvokeResult> _setTimer(Map<String, Object?> args) async {
    final minutesArg = args.containsKey('minutes') ? _asInt(args['minutes']) : null;
    final secondsArg = args.containsKey('seconds') ? _asInt(args['seconds']) : null;
    if (minutesArg == null && secondsArg == null) {
      return const ToolInvokeResult(
          {'error': 'minutes or seconds required'});
    }
    if ((minutesArg != null && minutesArg < 0) ||
        (secondsArg != null && secondsArg < 0)) {
      return const ToolInvokeResult(
          {'error': 'minutes and seconds must be >= 0'});
    }
    final totalSeconds = (minutesArg ?? 0) * 60 + (secondsArg ?? 0);
    if (totalSeconds < 1) {
      return const ToolInvokeResult(
          {'error': 'duration must be at least 1 second'});
    }
    if (totalSeconds > maxMinutes * 60) {
      return ToolInvokeResult({
        'error': 'duration must be <= $maxMinutes minutes',
        'seconds': totalSeconds,
      });
    }
    final label = _asLabel(args['label']);
    final t = now();
    final timer = PendingTimer(
      id: newTimerId(t),
      minutes: totalSeconds ~/ 60,
      label: label,
      firesAt: t.add(Duration(seconds: totalSeconds)),
      durationSeconds: totalSeconds,
    );
    String? replacedId;
    for (final old in List<PendingTimer>.from(timers.pending)) {
      await timers.remove(old.id);
      replacedId ??= old.id;
    }
    final stored = await timers.add(timer);
    if (!stored) {
      return const ToolInvokeResult({
        'error': 'too many timers',
        'max': TimerStore.maxPending,
      });
    }
    Log.i(_tag, 'timer ${timer.id} armed: ${timer.totalSeconds}s "${timer.label}"');
    // Deterministic ack. Timer tools are terminal for the model (no second
    // decode after them), so the phone confirms instead of trusting the
    // model to chain express(yes) in the same turn.
    showMood(BotMood.yes, labelPrefix: 'tool set_timer');
    return ToolInvokeResult(
      {
        'status': 'ok',
        'id': timer.id,
        'minutes': timer.minutes,
        'durationSeconds': timer.totalSeconds,
        'label': timer.label,
        'firesAt': timer.firesAt.toIso8601String(),
      },
      armed: timer,
      cancelledId: replacedId,
    );
  }

  Future<ToolInvokeResult> _cancelTimer(Map<String, Object?> _) async {
    final target = _resolveTimer();
    if (target == null) return _noMatchingTimer('tool cancel_timer');
    await timers.remove(target.id);
    Log.i(_tag, 'timer ${target.id} cancelled ("${target.label}")');
    showMood(BotMood.yes, labelPrefix: 'tool cancel_timer');
    return ToolInvokeResult(
      {
        'status': 'ok',
        'id': target.id,
        'label': target.label,
      },
      cancelledId: target.id,
    );
  }

  Future<ToolInvokeResult> _pauseTimer(Map<String, Object?> _) async {
    final target = _resolveTimer();
    if (target == null) return _noMatchingTimer('tool pause_timer');
    final paused = target.pauseAt(now());
    await timers.update(paused);
    Log.i(_tag, 'timer ${paused.id} paused ("${paused.label}"), '
        '${paused.remainingAt(now()).inSeconds}s left');
    showMood(BotMood.yes, labelPrefix: 'tool pause_timer');
    return ToolInvokeResult(
      {
        'status': 'ok',
        'id': paused.id,
        'label': paused.label,
        'remainingMs': paused.remainingAt(now()).inMilliseconds,
      },
      paused: paused,
    );
  }

  Future<ToolInvokeResult> _resumeTimer(Map<String, Object?> _) async {
    final target = _resolveTimer(preferPaused: true);
    if (target == null) return _noMatchingTimer('tool resume_timer');
    final resumed = target.resumeAt(now());
    await timers.update(resumed);
    Log.i(_tag, 'timer ${resumed.id} resumed ("${resumed.label}"), '
        'fires in ${resumed.remainingAt(now()).inSeconds}s');
    showMood(BotMood.yes, labelPrefix: 'tool resume_timer');
    return ToolInvokeResult(
      {
        'status': 'ok',
        'id': resumed.id,
        'label': resumed.label,
        'firesAt': resumed.firesAt.toIso8601String(),
      },
      resumed: resumed,
    );
  }

  ToolInvokeResult _noMatchingTimer(String labelPrefix) {
    showMood(BotMood.no, labelPrefix: labelPrefix);
    return const ToolInvokeResult({'error': 'no matching timer'});
  }

  PendingTimer? _resolveTimer({bool preferPaused = false}) {
    return pickTimer(timers.pending, preferPaused: preferPaused);
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

String _asLabel(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return 'timer';
}

(int, int, int) ledColor(Object? name) => switch ('$name') {
      'red' => (255, 0, 0),
      'green' => (0, 255, 0),
      'blue' => (0, 60, 255),
      'pink' => (255, 105, 180),
      'purple' => (160, 0, 255),
      'yellow' => (255, 200, 0),
      'orange' => (255, 120, 0),
      'white' => (255, 255, 255),
      'cyan' => (0, 200, 255),
      'off' => (0, 0, 0),
      _ => (255, 105, 180),
    };

LedPattern ledPattern(Object? name) => switch ('$name') {
      'blink' => LedPattern.blink,
      'breathe' => LedPattern.breathe,
      'off' => LedPattern.off,
      _ => LedPattern.solid,
    };

BotSound botSound(Object? name) => switch ('$name') {
      'beep' => BotSound.beep,
      'purr' => BotSound.purr,
      _ => BotSound.chirp,
    };
