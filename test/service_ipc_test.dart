// The UI <-> service messages cross an isolate boundary as plain maps;
// these tests pin the encode/decode contract on both directions.

import 'package:cute_bot/companion/bot_link.dart';
import 'package:cute_bot/companion/brain/brain_session.dart';
import 'package:cute_bot/companion/brain/latency_trace.dart';
import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:cute_bot/companion/service/service_ipc.dart';
import 'package:cute_bot/shared/ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UiCommand', () {
    test('all commands round-trip through their maps', () {
      const commands = <UiCommand>[
        SetLedUiCommand(
            red: 255, green: 10, blue: 0, pattern: LedPattern.breathe),
        WiggleUiCommand(),
        PlaySoundUiCommand(BotSound.purr),
        GetBatteryUiCommand(),
        SetLiveMonitorUiCommand(false),
        EchoLastUtteranceUiCommand(),
        SimulateUtteranceUiCommand(millis: 900),
        ClearTranscriptUiCommand(),
        RequestSnapshotUiCommand(),
        SetPhoneAlertsUiCommand(false),
        PhoneAlertUiCommand(packageName: 'com.whatsapp', category: 'msg'),
      ];
      for (final command in commands) {
        final decoded = UiCommand.fromMap(command.toMap());
        expect(decoded.runtimeType, command.runtimeType,
            reason: 'round-trip of ${command.runtimeType}');
      }
    });

    test('field values survive the round-trip', () {
      final led = UiCommand.fromMap(const SetLedUiCommand(
              red: 1, green: 2, blue: 3, pattern: LedPattern.blink)
          .toMap()) as SetLedUiCommand;
      expect((led.red, led.green, led.blue, led.pattern),
          (1, 2, 3, LedPattern.blink));

      final sim = UiCommand.fromMap(
              const SimulateUtteranceUiCommand(millis: 900).toMap())
          as SimulateUtteranceUiCommand;
      expect(sim.millis, 900);

      final monitor = UiCommand.fromMap(
              const SetLiveMonitorUiCommand(false).toMap())
          as SetLiveMonitorUiCommand;
      expect(monitor.enabled, isFalse);

      final alert = UiCommand.fromMap(const PhoneAlertUiCommand(
              packageName: 'com.whatsapp', category: 'msg')
          .toMap()) as PhoneAlertUiCommand;
      expect((alert.packageName, alert.category), ('com.whatsapp', 'msg'));

      final alerts = UiCommand.fromMap(
              const SetPhoneAlertsUiCommand(false).toMap())
          as SetPhoneAlertsUiCommand;
      expect(alerts.enabled, isFalse);
    });

    test('phoneAlert map as sent by the native listener decodes', () {
      // The Kotlin side builds this map by hand — pin the schema.
      final decoded = UiCommand.fromMap({
        'cmd': 'phoneAlert',
        'pkg': 'com.whatsapp',
        'category': 'msg',
      });
      expect(decoded, isA<PhoneAlertUiCommand>());
      final alert = decoded as PhoneAlertUiCommand;
      expect(alert.packageName, 'com.whatsapp');
      expect(alert.category, 'msg');

      // Missing fields degrade to empty strings, never throw.
      final bare = UiCommand.fromMap({'cmd': 'phoneAlert'})
          as PhoneAlertUiCommand;
      expect((bare.packageName, bare.category), ('', ''));
    });

    test('unknown or malformed input decodes to null', () {
      expect(UiCommand.fromMap(null), isNull);
      expect(UiCommand.fromMap('setLed'), isNull);
      expect(UiCommand.fromMap({'cmd': 'selfDestruct'}), isNull);
      expect(UiCommand.fromMap(const <String, Object?>{}), isNull);
    });
  });

  group('ServiceSnapshot', () {
    ServiceSnapshot sample() => ServiceSnapshot(
          sentAt: DateTime.fromMillisecondsSinceEpoch(2000),
          serviceStartedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          linkState: BotLinkState.ready,
          radioState: 'poweredOn',
          mtu: 247,
          botId: 'abcd1234',
          rssi: -55,
          reconnectAttempt: 2,
          linkError: null,
          brainState: BrainSessionState.responding,
          brainError: null,
          brainKind: 'Gemma 4 E2B',
          downloadPercent: 42,
          lastLatency: const LatencyTrace(
            submitMs: 80,
            firstTokenMs: 900,
            decodeMs: 400,
            totalMs: 1300,
            backend: 'gpu',
            firstTokenText: 'Hi',
          ),
          replayedEntries: 4,
          droppedUtterances: 1,
          responseText: 'Beep',
          lastResponseText: 'Boop',
          botState: BotState.listening,
          batteryPercent: 87,
          batteryMillivolts: 4012,
          liveMonitor: true,
          phoneAlertsEnabled: false,
          receivingUtterance: false,
          lastReceive: const ReceiveStatsSnapshot(
            frames: 120,
            framesLost: 2,
            audioMillis: 2400,
            wallMillis: 2100,
            realTimeRate: 1.14,
            checksumHex: 'deadbeef',
          ),
          lastEcho:
              const EchoStatsSnapshot(audioMillis: 2400, wallMillis: 2300),
          transcript: [
            TranscriptEntry(
                role: TranscriptRole.user,
                text: '(voice, 2.4 s)',
                timestamp: DateTime.fromMillisecondsSinceEpoch(1500)),
          ],
          activity: const ['12:00:01 Utterance: 120 frames'],
        );

      test('full snapshot round-trips', () {
        final decoded = ServiceSnapshot.fromMap(sample().toMap());
        expect(decoded, isNotNull);
        final s = decoded!;
        expect(s.linkState, BotLinkState.ready);
        expect(s.mtu, 247);
        expect(s.botId, 'abcd1234');
        expect(s.rssi, -55);
        expect(s.brainState, BrainSessionState.responding);
        expect(s.brainKind, 'Gemma 4 E2B');
        expect(s.downloadPercent, 42);
        expect(s.lastLatency!.firstTokenMs, 900);
        expect(s.lastLatency!.backend, 'gpu');
        expect(s.replayedEntries, 4);
        expect(s.droppedUtterances, 1);
        expect(s.responseText, 'Beep');
        expect(s.lastResponseText, 'Boop');
        expect(s.botState, BotState.listening);
        expect(s.batteryPercent, 87);
        expect(s.liveMonitor, isTrue);
        expect(s.phoneAlertsEnabled, isFalse);
        expect(s.lastReceive!.frames, 120);
        expect(s.lastReceive!.realTimeRate, closeTo(1.14, 1e-9));
        expect(s.lastReceive!.checksumHex, 'deadbeef');
        expect(s.lastEcho!.wallMillis, 2300);
        expect(s.transcript.single.text, '(voice, 2.4 s)');
        expect(s.activity.single, contains('120 frames'));
      });

    test('non-snapshot input decodes to null', () {
      expect(ServiceSnapshot.fromMap(null), isNull);
      expect(ServiceSnapshot.fromMap({'cmd': 'setLed'}), isNull);
      expect(ServiceSnapshot.fromMap({'kind': 'other'}), isNull);
    });

    test('missing optional fields decode to safe defaults', () {
      final minimal = ServiceSnapshot.fromMap({'kind': 'snapshot'});
      expect(minimal, isNotNull);
      expect(minimal!.linkState, BotLinkState.idle);
      expect(minimal.brainState, BrainSessionState.cold);
      expect(minimal.brainKind, 'unknown');
      expect(minimal.downloadPercent, isNull);
      expect(minimal.lastLatency, isNull);
      expect(minimal.mtu, 23);
      expect(minimal.lastReceive, isNull);
      expect(minimal.transcript, isEmpty);
      expect(minimal.activity, isEmpty);
    });

    test('unknown enum names fall back instead of throwing', () {
      final odd = ServiceSnapshot.fromMap({
        'kind': 'snapshot',
        'link': 'quantumEntangled',
        'brain': 'sentient',
        'botState': 'zoomies',
      });
      expect(odd!.linkState, BotLinkState.idle);
      expect(odd.brainState, BrainSessionState.cold);
      expect(odd.botState, BotState.idle);
    });
  });
}
