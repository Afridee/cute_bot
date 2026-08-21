/// Message schema between the companion UI isolate and the foreground
/// service isolate (M2).
///
/// flutter_foreground_task carries plain JSON-encodable values across the
/// engine boundary, so everything here is a `Map<String, Object?>` with a
/// discriminator key, encoded/decoded by hand and covered by unit tests.
/// Decoding is tolerant: unknown or malformed input returns null / defaults
/// instead of throwing, because the two isolates can briefly run different
/// versions of this file during a hot-restart.
library;

import '../brain/brain_session.dart';
import '../brain/transcript.dart';
import '../../shared/ble_protocol.dart';
import '../bot_link.dart';

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.firstWhere((v) => v.name == name, orElse: () => fallback);

int? _asInt(Object? v) => v is int ? v : null;
double _asDouble(Object? v, [double fallback = 0]) =>
    v is num ? v.toDouble() : fallback;

// ---------------------------------------------------------------------------
// UI -> service commands
// ---------------------------------------------------------------------------

sealed class UiCommand {
  const UiCommand();

  Map<String, Object?> toMap();

  /// Returns null for anything unrecognized.
  static UiCommand? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return switch (raw['cmd']) {
      'setLed' => SetLedUiCommand(
          red: _asInt(raw['r']) ?? 0,
          green: _asInt(raw['g']) ?? 0,
          blue: _asInt(raw['b']) ?? 0,
          pattern: _enumByName(
              LedPattern.values, raw['pattern'], LedPattern.solid),
        ),
      'wiggle' => const WiggleUiCommand(),
      'playSound' => PlaySoundUiCommand(
          _enumByName(BotSound.values, raw['sound'], BotSound.chirp)),
      'getBattery' => const GetBatteryUiCommand(),
      'setLiveMonitor' =>
        SetLiveMonitorUiCommand(raw['enabled'] == true),
      'echoLastUtterance' => const EchoLastUtteranceUiCommand(),
      'simulateUtterance' => SimulateUtteranceUiCommand(
          millis: _asInt(raw['millis']) ?? 1200),
      'clearTranscript' => const ClearTranscriptUiCommand(),
      'requestSnapshot' => const RequestSnapshotUiCommand(),
      'setPhoneAlerts' => SetPhoneAlertsUiCommand(raw['enabled'] == true),
      'phoneAlert' => PhoneAlertUiCommand(
          packageName: raw['pkg'] is String ? raw['pkg'] as String : '',
          category: raw['category'] is String ? raw['category'] as String : '',
        ),
      _ => null,
    };
  }
}

final class SetLedUiCommand extends UiCommand {
  const SetLedUiCommand({
    required this.red,
    required this.green,
    required this.blue,
    required this.pattern,
  });
  final int red, green, blue;
  final LedPattern pattern;

  @override
  Map<String, Object?> toMap() => {
        'cmd': 'setLed',
        'r': red,
        'g': green,
        'b': blue,
        'pattern': pattern.name,
      };
}

final class WiggleUiCommand extends UiCommand {
  const WiggleUiCommand();
  @override
  Map<String, Object?> toMap() => {'cmd': 'wiggle'};
}

final class PlaySoundUiCommand extends UiCommand {
  const PlaySoundUiCommand(this.sound);
  final BotSound sound;
  @override
  Map<String, Object?> toMap() => {'cmd': 'playSound', 'sound': sound.name};
}

final class GetBatteryUiCommand extends UiCommand {
  const GetBatteryUiCommand();
  @override
  Map<String, Object?> toMap() => {'cmd': 'getBattery'};
}

/// Play bot mic audio on the phone speaker as it arrives (debug).
final class SetLiveMonitorUiCommand extends UiCommand {
  const SetLiveMonitorUiCommand(this.enabled);
  final bool enabled;
  @override
  Map<String, Object?> toMap() =>
      {'cmd': 'setLiveMonitor', 'enabled': enabled};
}

/// Re-run the M1 duplex diagnostic through the service path.
final class EchoLastUtteranceUiCommand extends UiCommand {
  const EchoLastUtteranceUiCommand();
  @override
  Map<String, Object?> toMap() => {'cmd': 'echoLastUtterance'};
}

/// Feed the brain a synthetic (silent) utterance — lets the whole
/// utterance → brain → transcript path be exercised with no bot connected,
/// which is how kill/recovery is tested one-phone.
final class SimulateUtteranceUiCommand extends UiCommand {
  const SimulateUtteranceUiCommand({required this.millis});
  final int millis;
  @override
  Map<String, Object?> toMap() =>
      {'cmd': 'simulateUtterance', 'millis': millis};
}

final class ClearTranscriptUiCommand extends UiCommand {
  const ClearTranscriptUiCommand();
  @override
  Map<String, Object?> toMap() => {'cmd': 'clearTranscript'};
}

/// Ask the service to push a snapshot now (sent when the UI attaches).
final class RequestSnapshotUiCommand extends UiCommand {
  const RequestSnapshotUiCommand();
  @override
  Map<String, Object?> toMap() => {'cmd': 'requestSnapshot'};
}

/// Toggle "show phone alerts on bot". The service persists the choice so it
/// survives restarts (the toggle lives in the UI, the behavior in the
/// service).
final class SetPhoneAlertsUiCommand extends UiCommand {
  const SetPhoneAlertsUiCommand(this.enabled);
  final bool enabled;
  @override
  Map<String, Object?> toMap() => {'cmd': 'setPhoneAlerts', 'enabled': enabled};
}

/// A qualifying phone notification was posted. NOT sent by the UI: the
/// native CuteBotNotificationListenerService injects it over the same
/// task-data channel (ForegroundService.sendData) so there is exactly one
/// IPC schema. Content stays on the phone — only source package and
/// category cross over.
final class PhoneAlertUiCommand extends UiCommand {
  const PhoneAlertUiCommand({required this.packageName, required this.category});
  final String packageName;
  final String category;
  @override
  Map<String, Object?> toMap() =>
      {'cmd': 'phoneAlert', 'pkg': packageName, 'category': category};
}

// ---------------------------------------------------------------------------
// Service -> UI snapshot
// ---------------------------------------------------------------------------

/// Bandwidth-gate numbers for the last received utterance (see M1).
final class ReceiveStatsSnapshot {
  const ReceiveStatsSnapshot({
    required this.frames,
    required this.framesLost,
    required this.audioMillis,
    required this.wallMillis,
    required this.realTimeRate,
    required this.checksumHex,
  });

  final int frames;
  final int framesLost;
  final int audioMillis;
  final int wallMillis;
  final double realTimeRate;
  final String checksumHex;

  Map<String, Object?> toMap() => {
        'frames': frames,
        'lost': framesLost,
        'audioMs': audioMillis,
        'wallMs': wallMillis,
        'rate': realTimeRate,
        'crc': checksumHex,
      };

  static ReceiveStatsSnapshot? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return ReceiveStatsSnapshot(
      frames: _asInt(raw['frames']) ?? 0,
      framesLost: _asInt(raw['lost']) ?? 0,
      audioMillis: _asInt(raw['audioMs']) ?? 0,
      wallMillis: _asInt(raw['wallMs']) ?? 0,
      realTimeRate: _asDouble(raw['rate']),
      checksumHex: raw['crc'] is String ? raw['crc'] as String : '',
    );
  }
}

/// Throughput of the last echo back to the bot.
final class EchoStatsSnapshot {
  const EchoStatsSnapshot({
    required this.audioMillis,
    required this.wallMillis,
  });

  final int audioMillis;
  final int wallMillis;

  double get realTimeRate =>
      wallMillis <= 0 ? double.infinity : audioMillis / wallMillis;

  Map<String, Object?> toMap() =>
      {'audioMs': audioMillis, 'wallMs': wallMillis};

  static EchoStatsSnapshot? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return EchoStatsSnapshot(
      audioMillis: _asInt(raw['audioMs']) ?? 0,
      wallMillis: _asInt(raw['wallMs']) ?? 0,
    );
  }
}

/// Full service state, pushed to the UI on change (throttled) and every
/// heartbeat. The UI holds no state of its own — it renders this.
final class ServiceSnapshot {
  const ServiceSnapshot({
    required this.sentAt,
    required this.serviceStartedAt,
    required this.linkState,
    required this.radioState,
    required this.mtu,
    required this.botId,
    required this.rssi,
    required this.reconnectAttempt,
    required this.linkError,
    required this.brainState,
    required this.brainError,
    required this.replayedEntries,
    required this.droppedUtterances,
    required this.responseText,
    required this.lastResponseText,
    required this.botState,
    required this.batteryPercent,
    required this.batteryMillivolts,
    required this.liveMonitor,
    required this.phoneAlertsEnabled,
    required this.receivingUtterance,
    required this.lastReceive,
    required this.lastEcho,
    required this.transcript,
    required this.activity,
  });

  final DateTime sentAt;
  final DateTime serviceStartedAt;

  // Link
  final BotLinkState linkState;
  final String radioState;
  final int mtu;
  final String? botId;
  final int? rssi;
  final int reconnectAttempt;
  final String? linkError;

  // Brain
  final BrainSessionState brainState;
  final String? brainError;
  final int replayedEntries;
  final int droppedUtterances;
  final String responseText;
  final String lastResponseText;

  // Bot
  final BotState botState;
  final int? batteryPercent;
  final int? batteryMillivolts;

  /// "Show phone alerts on bot" (service-persisted; toggled from the UI).
  final bool phoneAlertsEnabled;

  // Audio diagnostics
  final bool liveMonitor;
  final bool receivingUtterance;
  final ReceiveStatsSnapshot? lastReceive;
  final EchoStatsSnapshot? lastEcho;

  /// Most recent transcript entries, oldest first (bounded — see service).
  final List<TranscriptEntry> transcript;

  /// Recent service activity lines, newest first.
  final List<String> activity;

  Map<String, Object?> toMap() => {
        'kind': 'snapshot',
        'sentAt': sentAt.millisecondsSinceEpoch,
        'startedAt': serviceStartedAt.millisecondsSinceEpoch,
        'link': linkState.name,
        'radio': radioState,
        'mtu': mtu,
        'botId': botId,
        'rssi': rssi,
        'reconnect': reconnectAttempt,
        'linkError': linkError,
        'brain': brainState.name,
        'brainError': brainError,
        'replayed': replayedEntries,
        'dropped': droppedUtterances,
        'responseText': responseText,
        'lastResponseText': lastResponseText,
        'botState': botState.name,
        'batteryPct': batteryPercent,
        'batteryMv': batteryMillivolts,
        'liveMonitor': liveMonitor,
        'phoneAlerts': phoneAlertsEnabled,
        'receiving': receivingUtterance,
        'lastReceive': lastReceive?.toMap(),
        'lastEcho': lastEcho?.toMap(),
        'transcript': [for (final e in transcript) e.toMap()],
        'activity': activity,
      };

  /// Returns null unless [raw] is a snapshot map.
  static ServiceSnapshot? fromMap(Object? raw) {
    if (raw is! Map || raw['kind'] != 'snapshot') return null;
    return ServiceSnapshot(
      sentAt: DateTime.fromMillisecondsSinceEpoch(_asInt(raw['sentAt']) ?? 0),
      serviceStartedAt:
          DateTime.fromMillisecondsSinceEpoch(_asInt(raw['startedAt']) ?? 0),
      linkState:
          _enumByName(BotLinkState.values, raw['link'], BotLinkState.idle),
      radioState: raw['radio'] is String ? raw['radio'] as String : 'unknown',
      mtu: _asInt(raw['mtu']) ?? 23,
      botId: raw['botId'] is String ? raw['botId'] as String : null,
      rssi: _asInt(raw['rssi']),
      reconnectAttempt: _asInt(raw['reconnect']) ?? 0,
      linkError: raw['linkError'] is String ? raw['linkError'] as String : null,
      brainState: _enumByName(
          BrainSessionState.values, raw['brain'], BrainSessionState.cold),
      brainError:
          raw['brainError'] is String ? raw['brainError'] as String : null,
      replayedEntries: _asInt(raw['replayed']) ?? 0,
      droppedUtterances: _asInt(raw['dropped']) ?? 0,
      responseText:
          raw['responseText'] is String ? raw['responseText'] as String : '',
      lastResponseText: raw['lastResponseText'] is String
          ? raw['lastResponseText'] as String
          : '',
      botState: _enumByName(BotState.values, raw['botState'], BotState.idle),
      batteryPercent: _asInt(raw['batteryPct']),
      batteryMillivolts: _asInt(raw['batteryMv']),
      liveMonitor: raw['liveMonitor'] == true,
      phoneAlertsEnabled: raw['phoneAlerts'] == true,
      receivingUtterance: raw['receiving'] == true,
      lastReceive: ReceiveStatsSnapshot.fromMap(raw['lastReceive']),
      lastEcho: EchoStatsSnapshot.fromMap(raw['lastEcho']),
      transcript: [
        if (raw['transcript'] is List)
          for (final item in raw['transcript'] as List)
            ?TranscriptEntry.fromMap(item),
      ],
      activity: [
        if (raw['activity'] is List)
          for (final line in raw['activity'] as List)
            if (line is String) line,
      ],
    );
  }
}
