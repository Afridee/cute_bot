/// Phone-side tool dispatch (M4).
///
/// Maps Gemma tool names onto BLE control writes, the phone timer store,
/// and battery telemetry. The same writes hit the simulator or a real
/// ESP32; firmware no-ops `wiggle` if there is no servo.
library;

import 'dart:async';

import '../../shared/ble_protocol.dart';
import '../../shared/log.dart';
import 'timer_store.dart';

const String _tag = 'BotBody';

/// Result of [BotBody.invoke]. [result] is what the model sees as the
/// tool response. [fired] is set when a restored timer is already due —
/// the caller should announce it, not arm a Dart timer.
final class ToolInvokeResult {
  const ToolInvokeResult(this.result, {this.armed});

  final Map<String, dynamic> result;

  /// Newly armed timer, if this was a successful `set_timer`.
  final PendingTimer? armed;
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
      default:
        Log.w(_tag, 'unhandled tool: $name');
        return ToolInvokeResult({'error': 'unknown tool $name'});
    }
  }

  Future<ToolInvokeResult> _setTimer(Map<String, Object?> args) async {
    final minutes = _asPositiveInt(args['minutes']);
    if (minutes == null) {
      return const ToolInvokeResult(
          {'error': 'minutes must be an integer >= 1'});
    }
    if (minutes > maxMinutes) {
      return ToolInvokeResult({
        'error': 'minutes must be <= $maxMinutes',
        'minutes': minutes,
      });
    }
    final label = _asLabel(args['label']);
    final t = now();
    final timer = PendingTimer(
      id: newTimerId(t),
      minutes: minutes,
      label: label,
      firesAt: t.add(Duration(minutes: minutes)),
    );
    final stored = await timers.add(timer);
    if (!stored) {
      return const ToolInvokeResult({
        'error': 'too many timers',
        'max': TimerStore.maxPending,
      });
    }
    Log.i(_tag, 'timer ${timer.id} armed: ${timer.minutes}m "${timer.label}"');
    return ToolInvokeResult(
      {
        'status': 'ok',
        'id': timer.id,
        'minutes': timer.minutes,
        'label': timer.label,
        'firesAt': timer.firesAt.toIso8601String(),
      },
      armed: timer,
    );
  }
}

int? _asPositiveInt(Object? value) {
  if (value is int) return value >= 1 ? value : null;
  if (value is double) {
    final n = value.round();
    return n >= 1 ? n : null;
  }
  if (value is String) {
    final n = int.tryParse(value);
    return n != null && n >= 1 ? n : null;
  }
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
