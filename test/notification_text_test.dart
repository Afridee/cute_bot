// Unit tests for the persistent-notification text (M2.5). Pure
// function, no service or device needed.

import 'package:flutter_test/flutter_test.dart';

import 'package:cute_bot/companion/bot_link.dart';
import 'package:cute_bot/companion/brain/brain_session.dart';
import 'package:cute_bot/companion/service/notification_text.dart';

void main() {
  group('formatServiceNotificationText', () {
    test('the canonical happy path: connected, battery known, brain ready',
        () {
      expect(
        formatServiceNotificationText(
          linkState: BotLinkState.ready,
          brainState: BrainSessionState.ready,
          batteryPercent: 82,
        ),
        'Connected · 82% · idle',
      );
    });

    test('battery segment is omitted until first telemetry', () {
      expect(
        formatServiceNotificationText(
          linkState: BotLinkState.scanning,
          brainState: BrainSessionState.warming,
          batteryPercent: null,
        ),
        'Looking for bot · warming up',
      );
    });

    test('every link state maps to a human label', () {
      final labels = {
        for (final state in BotLinkState.values)
          state: formatServiceNotificationText(
            linkState: state,
            brainState: BrainSessionState.ready,
            batteryPercent: null,
          ).split(' · ').first,
      };
      expect(labels[BotLinkState.ready], 'Connected');
      expect(labels[BotLinkState.scanning], 'Looking for bot');
      expect(labels[BotLinkState.connecting], 'Connecting');
      expect(labels[BotLinkState.configuring], 'Connecting');
      expect(labels[BotLinkState.reconnectWait], 'Reconnecting');
      expect(labels[BotLinkState.bluetoothOff], 'Bluetooth off');
      expect(labels[BotLinkState.unauthorized], 'Needs permission');
      expect(labels[BotLinkState.unsupported], 'BLE unsupported');
      expect(labels[BotLinkState.idle], 'Bot offline');
      // No enum value may fall through to an empty label.
      expect(labels.values.every((l) => l.isNotEmpty), isTrue);
    });

    test('every brain state maps to a human label', () {
      final labels = {
        for (final state in BrainSessionState.values)
          state: formatServiceNotificationText(
            linkState: BotLinkState.ready,
            brainState: state,
            batteryPercent: null,
          ).split(' · ').last,
      };
      expect(labels[BrainSessionState.cold], 'brain off');
      expect(labels[BrainSessionState.warming], 'warming up');
      expect(labels[BrainSessionState.ready], 'idle');
      expect(labels[BrainSessionState.thinking], 'thinking');
      expect(labels[BrainSessionState.responding], 'responding');
    });

    test('busy state with battery keeps the three-segment shape', () {
      expect(
        formatServiceNotificationText(
          linkState: BotLinkState.reconnectWait,
          brainState: BrainSessionState.thinking,
          batteryPercent: 5,
        ),
        'Reconnecting · 5% · thinking',
      );
    });
  });
}
