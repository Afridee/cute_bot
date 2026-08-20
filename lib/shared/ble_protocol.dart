/// BLE protocol contract between the companion app and the bot
/// (simulator now, ESP32 firmware later).
///
/// KEEP THIS FILE DEPENDENCY-FREE PLAIN DART (dart:typed_data only) so the
/// ESP32 firmware can be ported from it line by line.
///
/// ## Freeze status
///
/// - CONTROL PLANE (UUIDs, frame header, message types, control/telemetry
///   encoding): FROZEN after M0. Changes require an explicit callout.
/// - AUDIO PLANE (codec, sample rate, chunk sizing — see [AudioWireFormat]
///   and `adpcm.dart`): PROVISIONAL until the M1 bandwidth gate passes.
///
/// ## Roles
///
/// The bot (simulator or ESP32) is the BLE *peripheral* and GATT server.
/// The companion phone is the *central*. Directions below are named from the
/// bot's point of view: "from bot" = notification, "to bot" = write.
///
/// ## Utterance endpointing
///
/// v1 is push-to-talk: the bot streams mic audio only while the talk control
/// is held. Utterance boundaries are carried in the frame header —
/// [FrameFlags.startOfUtterance] on the first chunk, sequence numbers on
/// every chunk, [FrameFlags.endOfUtterance] on the last chunk (which may
/// carry an empty payload). VAD or a wake word can replace push-to-talk
/// later without changing this wire format; the boundary markers are part
/// of the contract from day one.
///
/// ## Pairing / bonding decision
///
/// DECISION (M0): the link is OPEN — no bonding, no encrypted
/// characteristics — for the simulator phase, because it removes a whole
/// class of two-phone pairing friction while the protocol is young.
/// DIRECTION: before real hardware ships, the link moves to bonded-only
/// with encrypted writes (anyone in radio range must not be able to drive
/// servos or the speaker). That change touches GATT permissions only, not
/// message encoding. Tracked by [PairingPolicy].
///
/// ADDENDUM (M2.5, CompanionDeviceManager wake-up): CDM device-presence
/// tracking is identity-based, and the bot advertises with a rotating
/// resolvable private address (Android peripherals always do; the
/// simulator cannot opt out — bluetooth_low_energy exposes no static-
/// address API). Resolution chosen: the companion BONDS the bot during CDM
/// association, so the phone holds the IRK and can resolve the rotating
/// address across rotations. This does NOT change [kPairingPolicy]: the
/// GATT characteristics stay open/unencrypted, bonding is initiated by the
/// companion as a CDM implementation detail and the bot merely accepts the
/// OS pairing flow (no simulator code change; ESP32 firmware note: either
/// accept Just Works pairing, or advertise a static address and make
/// bonding unnecessary for presence). The M0 direction — bonded-only with
/// encrypted writes before real hardware — is unchanged and this addendum
/// is a step toward it.
library;

import 'dart:typed_data';

/// Protocol version carried nowhere on the wire yet; bump on breaking
/// change and add to advertising data if we ever need coexistence.
const int kProtocolVersion = 1;

/// Pairing policy — see the library doc above for the rationale.
enum PairingPolicy {
  /// Simulator phase: no bonding required.
  open,

  /// Real hardware: bonded-only, encrypted writes. NOT YET ACTIVE.
  bondedOnly,
}

/// The policy currently in force.
const PairingPolicy kPairingPolicy = PairingPolicy.open;

// ---------------------------------------------------------------------------
// GATT layout  (CONTROL PLANE — FROZEN after M0)
// ---------------------------------------------------------------------------

/// Custom 128-bit UUIDs. "cb07" = Cute Bot; the tail is a randomly
/// generated suffix shared by the whole service.
abstract final class BotUuids {
  static const String service = 'cb070001-4bd9-4f22-9e15-8c2a51d1f27e';

  /// Bot mic -> phone. NOTIFY. Carries [AudioChunkMessage] frames.
  static const String audioFromBot = 'cb070002-4bd9-4f22-9e15-8c2a51d1f27e';

  /// Phone -> bot speaker. WRITE WITHOUT RESPONSE. Carries
  /// [AudioChunkMessage] frames.
  static const String audioToBot = 'cb070003-4bd9-4f22-9e15-8c2a51d1f27e';

  /// Phone -> bot actuators. WRITE (with response, so the phone knows the
  /// command landed). Carries [ControlMessage] frames. Control writes must
  /// be prioritized over queued audio writes by the sender.
  static const String control = 'cb070004-4bd9-4f22-9e15-8c2a51d1f27e';

  /// Bot -> phone status. NOTIFY + READ. Carries [TelemetryMessage] and
  /// [BotStateMessage] frames.
  static const String telemetry = 'cb070005-4bd9-4f22-9e15-8c2a51d1f27e';
}

/// Local name used in advertising. Keep short: name + 128-bit service UUID
/// must fit the advertisement payload or Android fails with
/// ADVERTISE_FAILED_DATA_TOO_LARGE.
const String kAdvertisedName = 'CuteBot';

// ---------------------------------------------------------------------------
// Audio wire format  (AUDIO PLANE — PROVISIONAL until M1 bandwidth gate)
// ---------------------------------------------------------------------------

/// Bandwidth math behind these numbers:
/// raw 16 kHz / 16-bit mono PCM = 256 kbps. Realistic sustained BLE
/// notification throughput on Android is ~50–100 kbps even at MTU 517.
/// IMA ADPCM compresses 4:1 -> 64 kbps + ~5% framing overhead, which sits
/// inside that window. Opus would be better per bit but is a real CPU/port
/// cost on an ESP32; ADPCM decodes in a few lines of integer C.
abstract final class AudioWireFormat {
  static const int sampleRate = 16000; // Hz
  static const int bitsPerSample = 16; // signed little-endian PCM pre-codec
  static const int channels = 1;

  /// Codec: IMA ADPCM, 4 bits/sample, block layout defined in adpcm.dart.
  /// Each audio frame payload is exactly one self-contained ADPCM block,
  /// so a lost frame costs 20 ms of audio, never decoder sync.
  static const String codec = 'ima-adpcm';

  /// Samples per audio frame. 320 samples = 20 ms at 16 kHz.
  static const int samplesPerFrame = 320;

  /// Milliseconds of audio per frame.
  static const int millisPerFrame =
      samplesPerFrame * 1000 ~/ sampleRate; // 20

  /// Encoded ADPCM block size: 4-byte state header + 4 bits per sample.
  static const int adpcmBlockBytes = 4 + samplesPerFrame ~/ 2; // 164

  /// Full audio frame on the wire: frame header + ADPCM block. This must
  /// fit in (ATT_MTU - 3) bytes; 168 needs MTU >= 171, hence the request
  /// below. If the negotiated MTU is smaller, the *sender* must fall back
  /// to a smaller frame (fewer samples per block) — receivers accept any
  /// even sample count.
  static const int audioFrameBytes = FrameHeader.byteLength + adpcmBlockBytes;
}

/// MTU the central should request on connect. Android may grant less;
/// 517 is the Android maximum.
const int kPreferredMtu = 517;

// ---------------------------------------------------------------------------
// Frame header  (CONTROL PLANE — FROZEN after M0)
// ---------------------------------------------------------------------------

/// Every message on every characteristic starts with this 4-byte header.
/// All multi-byte integers in this protocol are LITTLE-ENDIAN.
///
/// ```text
/// byte 0   message type        (MessageType)
/// byte 1   flags               (FrameFlags bit set)
/// byte 2-3 uint16 LE sequence  (per-characteristic, wraps at 0xFFFF)
/// ```
final class FrameHeader {
  const FrameHeader({
    required this.type,
    required this.sequence,
    this.flags = 0,
  });

  static const int byteLength = 4;

  final int type;
  final int flags;

  /// Wraps modulo [maxSequence] + 1.
  final int sequence;

  static const int maxSequence = 0xFFFF;

  bool get startOfUtterance => flags & FrameFlags.startOfUtterance != 0;
  bool get endOfUtterance => flags & FrameFlags.endOfUtterance != 0;

  void writeTo(ByteData data, int offset) {
    data.setUint8(offset, type);
    data.setUint8(offset + 1, flags);
    data.setUint16(offset + 2, sequence, Endian.little);
  }

  static FrameHeader readFrom(ByteData data, int offset) {
    return FrameHeader(
      type: data.getUint8(offset),
      flags: data.getUint8(offset + 1),
      sequence: data.getUint16(offset + 2, Endian.little),
    );
  }
}

/// Message type values (frame header byte 0).
abstract final class MessageType {
  static const int audioChunk = 0x01;
  static const int control = 0x02;
  static const int telemetry = 0x03;
  static const int botState = 0x04;
}

/// Flag bits (frame header byte 1).
abstract final class FrameFlags {
  /// First audio chunk of an utterance. Receiver resets reassembly state.
  static const int startOfUtterance = 0x01;

  /// Last audio chunk of an utterance. May carry an empty payload.
  static const int endOfUtterance = 0x02;
}

/// Thrown when a frame cannot be decoded. Receivers should log and drop —
/// a malformed frame from the radio must never crash the app.
final class ProtocolException implements Exception {
  const ProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// Base type for everything that crosses the link.
sealed class BotMessage {
  const BotMessage();

  FrameHeader get header;

  /// Encodes the payload (bytes after the frame header).
  Uint8List encodePayload();

  /// Full wire frame: header + payload.
  Uint8List encode() {
    final payload = encodePayload();
    final frame = Uint8List(FrameHeader.byteLength + payload.length);
    header.writeTo(ByteData.sublistView(frame), 0);
    frame.setRange(FrameHeader.byteLength, frame.length, payload);
    return frame;
  }

  /// Decodes any protocol frame. Throws [ProtocolException] on garbage.
  static BotMessage decode(Uint8List frame) {
    if (frame.length < FrameHeader.byteLength) {
      throw ProtocolException(
          'frame too short: ${frame.length} < ${FrameHeader.byteLength}');
    }
    final header = FrameHeader.readFrom(ByteData.sublistView(frame), 0);
    final payload = Uint8List.sublistView(frame, FrameHeader.byteLength);
    return switch (header.type) {
      MessageType.audioChunk => AudioChunkMessage._decode(header, payload),
      MessageType.control => ControlMessage._decode(header, payload),
      MessageType.telemetry => TelemetryMessage._decode(header, payload),
      MessageType.botState => BotStateMessage._decode(header, payload),
      _ => throw ProtocolException(
          'unknown message type 0x${header.type.toRadixString(16)}'),
    };
  }
}

/// One chunk of ADPCM-encoded audio. Payload is exactly one self-contained
/// ADPCM block (see adpcm.dart for the block layout). Flows in both
/// directions (bot mic -> phone, phone TTS -> bot speaker).
final class AudioChunkMessage extends BotMessage {
  const AudioChunkMessage({
    required this.sequence,
    required this.adpcmBlock,
    this.isUtteranceStart = false,
    this.isUtteranceEnd = false,
  });

  final int sequence;
  final Uint8List adpcmBlock;
  final bool isUtteranceStart;
  final bool isUtteranceEnd;

  @override
  FrameHeader get header => FrameHeader(
        type: MessageType.audioChunk,
        sequence: sequence,
        flags: (isUtteranceStart ? FrameFlags.startOfUtterance : 0) |
            (isUtteranceEnd ? FrameFlags.endOfUtterance : 0),
      );

  @override
  Uint8List encodePayload() => adpcmBlock;

  static AudioChunkMessage _decode(FrameHeader header, Uint8List payload) {
    // An end-of-utterance frame may be empty; anything else must carry at
    // least an ADPCM block header.
    if (payload.isNotEmpty && payload.length < 5) {
      throw ProtocolException(
          'audio payload too short for an ADPCM block: ${payload.length}');
    }
    return AudioChunkMessage(
      sequence: header.sequence,
      adpcmBlock: payload,
      isUtteranceStart: header.startOfUtterance,
      isUtteranceEnd: header.endOfUtterance,
    );
  }
}

/// Command identifiers (first payload byte of a control frame).
abstract final class ControlCommandId {
  static const int setLed = 0x01;
  static const int wiggle = 0x02;
  static const int playSound = 0x03;
  static const int getBattery = 0x04;
}

/// LED animation patterns for [SetLedCommand].
enum LedPattern {
  off(0),
  solid(1),
  blink(2),
  breathe(3);

  const LedPattern(this.wireValue);
  final int wireValue;

  static LedPattern fromWire(int value) => switch (value) {
        0 => LedPattern.off,
        1 => LedPattern.solid,
        2 => LedPattern.blink,
        3 => LedPattern.breathe,
        _ => throw ProtocolException('unknown LED pattern $value'),
      };
}

/// Built-in bot sounds for [PlaySoundCommand]. The set is small and fixed;
/// firmware ships the samples.
enum BotSound {
  chirp(0),
  beep(1),
  purr(2),
  alarm(3);

  const BotSound(this.wireValue);
  final int wireValue;

  static BotSound fromWire(int value) => switch (value) {
        0 => BotSound.chirp,
        1 => BotSound.beep,
        2 => BotSound.purr,
        3 => BotSound.alarm,
        _ => throw ProtocolException('unknown sound $value'),
      };
}

/// Phone -> bot actuator command. Payload: [command id u8][args...].
sealed class ControlMessage extends BotMessage {
  const ControlMessage({required this.sequence});

  final int sequence;

  int get commandId;

  /// Command arguments (payload bytes after the command id).
  Uint8List encodeArgs();

  @override
  FrameHeader get header =>
      FrameHeader(type: MessageType.control, sequence: sequence);

  @override
  Uint8List encodePayload() {
    final args = encodeArgs();
    final payload = Uint8List(1 + args.length);
    payload[0] = commandId;
    payload.setRange(1, payload.length, args);
    return payload;
  }

  static ControlMessage _decode(FrameHeader header, Uint8List payload) {
    if (payload.isEmpty) {
      throw ProtocolException('control frame has no command id');
    }
    final args = Uint8List.sublistView(payload, 1);
    final seq = header.sequence;
    return switch (payload[0]) {
      ControlCommandId.setLed => SetLedCommand._decodeArgs(seq, args),
      ControlCommandId.wiggle => WiggleCommand(sequence: seq),
      ControlCommandId.playSound => PlaySoundCommand._decodeArgs(seq, args),
      ControlCommandId.getBattery => GetBatteryCommand(sequence: seq),
      _ => throw ProtocolException(
          'unknown control command 0x${payload[0].toRadixString(16)}'),
    };
  }
}

/// Args: [r u8][g u8][b u8][pattern u8].
final class SetLedCommand extends ControlMessage {
  const SetLedCommand({
    required super.sequence,
    required this.red,
    required this.green,
    required this.blue,
    required this.pattern,
  });

  final int red, green, blue;
  final LedPattern pattern;

  @override
  int get commandId => ControlCommandId.setLed;

  @override
  Uint8List encodeArgs() =>
      Uint8List.fromList([red, green, blue, pattern.wireValue]);

  static SetLedCommand _decodeArgs(int sequence, Uint8List args) {
    if (args.length < 4) {
      throw ProtocolException('set_led needs 4 arg bytes, got ${args.length}');
    }
    return SetLedCommand(
      sequence: sequence,
      red: args[0],
      green: args[1],
      blue: args[2],
      pattern: LedPattern.fromWire(args[3]),
    );
  }
}

/// No args. Firmware performs its one canned wiggle.
final class WiggleCommand extends ControlMessage {
  const WiggleCommand({required super.sequence});

  @override
  int get commandId => ControlCommandId.wiggle;

  @override
  Uint8List encodeArgs() => Uint8List(0);
}

/// Args: [sound u8].
final class PlaySoundCommand extends ControlMessage {
  const PlaySoundCommand({required super.sequence, required this.sound});

  final BotSound sound;

  @override
  int get commandId => ControlCommandId.playSound;

  @override
  Uint8List encodeArgs() => Uint8List.fromList([sound.wireValue]);

  static PlaySoundCommand _decodeArgs(int sequence, Uint8List args) {
    if (args.isEmpty) {
      throw ProtocolException('play_sound needs 1 arg byte');
    }
    return PlaySoundCommand(sequence: sequence, sound: BotSound.fromWire(args[0]));
  }
}

/// No args. Bot answers with a [BatteryStatusMessage] on the telemetry
/// characteristic.
final class GetBatteryCommand extends ControlMessage {
  const GetBatteryCommand({required super.sequence});

  @override
  int get commandId => ControlCommandId.getBattery;

  @override
  Uint8List encodeArgs() => Uint8List(0);
}

/// Telemetry kinds (first payload byte of a telemetry frame).
abstract final class TelemetryKind {
  static const int battery = 0x01;
}

/// Bot -> phone telemetry. Payload: [kind u8][data...].
sealed class TelemetryMessage extends BotMessage {
  const TelemetryMessage({required this.sequence});

  final int sequence;

  int get kind;

  Uint8List encodeData();

  @override
  FrameHeader get header =>
      FrameHeader(type: MessageType.telemetry, sequence: sequence);

  @override
  Uint8List encodePayload() {
    final data = encodeData();
    final payload = Uint8List(1 + data.length);
    payload[0] = kind;
    payload.setRange(1, payload.length, data);
    return payload;
  }

  static TelemetryMessage _decode(FrameHeader header, Uint8List payload) {
    if (payload.isEmpty) {
      throw ProtocolException('telemetry frame has no kind byte');
    }
    final data = Uint8List.sublistView(payload, 1);
    return switch (payload[0]) {
      TelemetryKind.battery =>
        BatteryStatusMessage._decodeData(header.sequence, data),
      _ => throw ProtocolException(
          'unknown telemetry kind 0x${payload[0].toRadixString(16)}'),
    };
  }
}

/// Data: [percent u8][charging u8 (0/1)][millivolts u16 LE].
final class BatteryStatusMessage extends TelemetryMessage {
  const BatteryStatusMessage({
    required super.sequence,
    required this.percent,
    required this.charging,
    required this.millivolts,
  });

  final int percent;
  final bool charging;
  final int millivolts;

  @override
  int get kind => TelemetryKind.battery;

  @override
  Uint8List encodeData() {
    final data = Uint8List(4);
    final view = ByteData.sublistView(data);
    view.setUint8(0, percent);
    view.setUint8(1, charging ? 1 : 0);
    view.setUint16(2, millivolts, Endian.little);
    return data;
  }

  static BatteryStatusMessage _decodeData(int sequence, Uint8List data) {
    if (data.length < 4) {
      throw ProtocolException(
          'battery status needs 4 data bytes, got ${data.length}');
    }
    final view = ByteData.sublistView(data);
    return BatteryStatusMessage(
      sequence: sequence,
      percent: view.getUint8(0),
      charging: view.getUint8(1) != 0,
      millivolts: view.getUint16(2, Endian.little),
    );
  }
}

/// Coarse bot state, mirrored to LEDs/face on real hardware. Also lets the
/// half-duplex rule (mic muted while speaking — see "Echo" in the brief)
/// be protocol-visible instead of an accident of buffering.
enum BotState {
  idle(0),
  listening(1),
  thinking(2),
  speaking(3),
  warming(4),
  error(5);

  const BotState(this.wireValue);
  final int wireValue;

  static BotState fromWire(int value) => switch (value) {
        0 => BotState.idle,
        1 => BotState.listening,
        2 => BotState.thinking,
        3 => BotState.speaking,
        4 => BotState.warming,
        5 => BotState.error,
        _ => throw ProtocolException('unknown bot state $value'),
      };
}

/// Bot -> phone state announcement. Payload: [state u8].
final class BotStateMessage extends BotMessage {
  const BotStateMessage({required this.sequence, required this.state});

  final int sequence;
  final BotState state;

  @override
  FrameHeader get header =>
      FrameHeader(type: MessageType.botState, sequence: sequence);

  @override
  Uint8List encodePayload() => Uint8List.fromList([state.wireValue]);

  static BotStateMessage _decode(FrameHeader header, Uint8List payload) {
    if (payload.isEmpty) {
      throw ProtocolException('bot state frame has no state byte');
    }
    return BotStateMessage(
      sequence: header.sequence,
      state: BotState.fromWire(payload[0]),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Per-characteristic sequence counter, wrapping at [FrameHeader.maxSequence].
final class SequenceCounter {
  int _next = 0;

  /// Returns the current value and advances.
  int next() {
    final value = _next;
    _next = (_next + 1) & FrameHeader.maxSequence;
    return value;
  }

  void reset() => _next = 0;
}
