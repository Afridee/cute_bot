// Bot simulator: this phone acts as the BLE *peripheral* (GATT server),
// standing in for the ESP32 until hardware exists.
//
// Responsibilities:
// - advertise the bot service, accept a companion/scanner connection
// - push-to-talk: stream mic audio out as ADPCM chunks (audioFromBot)
// - accept audio in (audioToBot) and play it on the phone speaker
// - accept control writes and reflect them on screen (LED box, log)
// - answer battery reads/requests and announce bot state transitions

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';

import '../shared/adpcm.dart';
import '../shared/audio_transport.dart';
import '../shared/ble_protocol.dart';
import '../shared/log.dart';

const String _tag = 'Simulator';

/// One line in the on-screen activity log.
final class SimulatorLogEntry {
  SimulatorLogEntry(this.message) : timestamp = DateTime.now();
  final DateTime timestamp;
  final String message;
}

enum SimulatorChatRole { user, bot }

/// One bubble in the simulator conversation view (M3 caption stand-in).
final class SimulatorChatLine {
  SimulatorChatLine({
    required this.role,
    required this.text,
    this.streaming = false,
  }) : timestamp = DateTime.now();

  final DateTime timestamp;
  final SimulatorChatRole role;
  String text;
  bool streaming;
}

final class SimulatorController extends ChangeNotifier {
  SimulatorController() {
    _peripheral = PeripheralManager();
  }

  late final PeripheralManager _peripheral;
  final AudioRecorder _recorder = AudioRecorder();

  final List<StreamSubscription> _bleSubscriptions = [];
  StreamSubscription<Uint8List>? _micSubscription;

  // --- state surfaced to the UI ---

  BluetoothLowEnergyState radioState = BluetoothLowEnergyState.unknown;
  bool advertising = false;
  String? fatalError; // unrecoverable for this session (e.g. unauthorized)

  /// Centrals currently subscribed to each notify characteristic,
  /// keyed by central UUID string.
  final Map<String, Central> _audioSubscribers = {};
  final Map<String, Central> _telemetrySubscribers = {};
  final Map<String, int> mtuByCentral = {};

  int get subscriberCount => _audioSubscribers.length;
  bool get hasConnection =>
      _audioSubscribers.isNotEmpty || _telemetrySubscribers.isNotEmpty;

  // LED as commanded over the control characteristic.
  int ledRed = 0, ledGreen = 0, ledBlue = 0;
  LedPattern ledPattern = LedPattern.off;

  // Bumped on each wiggle command so the UI can animate.
  int wiggleCount = 0;

  bool talking = false;
  int micFramesSent = 0;

  bool receivingAudio = false;
  int audioFramesReceived = 0;
  int lastAudioSequence = -1;
  int audioFramesLost = 0;

  BotState botState = BotState.idle;

  final List<SimulatorLogEntry> activityLog = [];
  static const int _maxLogEntries = 60;

  /// Spoken turns as seen on this phone: local "you spoke" + captions
  /// the companion writes over [ShowTextCommand].
  final List<SimulatorChatLine> conversation = [];
  static const int _maxChatLines = 40;

  // Fake battery served until real hardware exists.
  static const int _batteryPercent = 87;
  static const bool _batteryCharging = false;
  static const int _batteryMillivolts = 3970;

  // --- GATT plumbing ---

  late final GATTCharacteristic _audioFromBotChar;
  late final GATTCharacteristic _audioToBotChar;
  late final GATTCharacteristic _controlChar;
  late final GATTCharacteristic _telemetryChar;

  final SequenceCounter _audioOutSeq = SequenceCounter();
  final SequenceCounter _telemetrySeq = SequenceCounter();

  final ImaAdpcmEncoder _micEncoder = ImaAdpcmEncoder();
  final BytesBuilder _micPending = BytesBuilder(copy: true);
  bool _micUtteranceStarted = false;

  /// Checksum of the ADPCM payload sent this utterance. Shown on screen so
  /// the M1 human test can compare it against the companion's received
  /// checksum: equal values prove byte-identical delivery.
  final Fnv32 _micChecksum = Fnv32();

  bool _playbackReady = false;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _bleSubscriptions.add(_peripheral.stateChanged.listen(_onRadioState));
    _bleSubscriptions.add(
        _peripheral.characteristicNotifyStateChanged.listen(_onNotifyState));
    _bleSubscriptions.add(
        _peripheral.characteristicWriteRequested.listen(_onWriteRequested));
    _bleSubscriptions.add(
        _peripheral.characteristicReadRequested.listen(_onReadRequested));
    _bleSubscriptions.add(_peripheral.mtuChanged.listen((e) {
      mtuByCentral[e.central.uuid.toString()] = e.mtu;
      _logActivity('MTU for ${_shortId(e.central)}: ${e.mtu}');
    }));
    _bleSubscriptions.add(_peripheral.connectionStateChanged.listen((e) {
      final connected = e.state == ConnectionState.connected;
      _logActivity(
          '${_shortId(e.central)} ${connected ? 'connected' : 'disconnected'}');
      final id = e.central.uuid.toString();
      if (connected) {
        // Phone-to-phone: the companion's CCCD write often never ACKs on
        // OEM Android stacks, so characteristicNotifyStateChanged never
        // fires. Treat a connected central as subscribed; nRF Connect
        // still toggles via _onNotifyState when CCCD does arrive.
        _audioSubscribers[id] = e.central;
        _telemetrySubscribers[id] = e.central;
      } else {
        _audioSubscribers.remove(id);
        _telemetrySubscribers.remove(id);
        mtuByCentral.remove(id);
      }
      notifyListeners();
    }));

    try {
      await FlutterPcmSound.setup(
        sampleRate: AudioWireFormat.sampleRate,
        channelCount: AudioWireFormat.channels,
      );
      await FlutterPcmSound.setFeedThreshold(0);
      _playbackReady = true;
    } catch (e) {
      // Playback failure must not take down the GATT server.
      Log.e(_tag, 'PCM playback setup failed', e);
      _logActivity('Speaker unavailable: $e');
    }

    _onRadioState(BluetoothLowEnergyStateChangedEventArgs(_peripheral.state));
  }

  Future<void> _onRadioState(
      BluetoothLowEnergyStateChangedEventArgs args) async {
    radioState = args.state;
    Log.i(_tag, 'radio state: ${args.state.name}');

    switch (args.state) {
      case BluetoothLowEnergyState.unauthorized:
        final granted = await _peripheral.authorize();
        if (!granted) {
          fatalError = 'Bluetooth permission denied. Grant it in settings.';
          Log.e(_tag, 'BLE permissions denied');
        }
      case BluetoothLowEnergyState.poweredOn:
        fatalError = null;
        await _publishAndAdvertise();
      case BluetoothLowEnergyState.poweredOff:
        // Bluetooth toggled off: drop session state; we re-advertise on
        // the next poweredOn event.
        advertising = false;
        _audioSubscribers.clear();
        _telemetrySubscribers.clear();
        mtuByCentral.clear();
        await _stopTalkingInternal(notifyPeers: false);
        _logActivity('Bluetooth is off');
      case BluetoothLowEnergyState.unsupported:
        fatalError = 'This device does not support BLE peripheral mode.';
      case BluetoothLowEnergyState.unknown:
        break;
    }
    notifyListeners();
  }

  Future<void> _publishAndAdvertise() async {
    try {
      await _peripheral.removeAllServices();

      _audioFromBotChar = GATTCharacteristic.mutable(
        uuid: UUID.fromString(BotUuids.audioFromBot),
        properties: [GATTCharacteristicProperty.notify],
        // Open link for the simulator phase; see PairingPolicy in
        // ble_protocol.dart. bondedOnly will switch these to *Encrypted.
        permissions: [GATTCharacteristicPermission.read],
        descriptors: [],
      );
      _audioToBotChar = GATTCharacteristic.mutable(
        uuid: UUID.fromString(BotUuids.audioToBot),
        properties: [
          GATTCharacteristicProperty.writeWithoutResponse,
          GATTCharacteristicProperty.write,
        ],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: [],
      );
      _controlChar = GATTCharacteristic.mutable(
        uuid: UUID.fromString(BotUuids.control),
        properties: [GATTCharacteristicProperty.write],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: [],
      );
      _telemetryChar = GATTCharacteristic.mutable(
        uuid: UUID.fromString(BotUuids.telemetry),
        properties: [
          GATTCharacteristicProperty.read,
          GATTCharacteristicProperty.notify,
        ],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: [],
      );

      await _peripheral.addService(GATTService(
        uuid: UUID.fromString(BotUuids.service),
        isPrimary: true,
        includedServices: [],
        characteristics: [
          _audioFromBotChar,
          _audioToBotChar,
          _controlChar,
          _telemetryChar,
        ],
      ));

      await _peripheral.startAdvertising(Advertisement(
        name: kAdvertisedName,
        serviceUUIDs: [UUID.fromString(BotUuids.service)],
      ));
      advertising = true;
      _logActivity('Advertising as $kAdvertisedName');
      Log.i(_tag, 'advertising started');
    } catch (e) {
      advertising = false;
      _logActivity('Advertising failed: $e');
      Log.e(_tag, 'failed to publish service / advertise', e);
    }
    notifyListeners();
  }

  // --- inbound GATT events ---

  void _onNotifyState(GATTCharacteristicNotifyStateChangedEventArgs args) {
    final id = args.central.uuid.toString();
    final Map<String, Central>? registry;
    final String name;
    if (args.characteristic.uuid == _audioFromBotChar.uuid) {
      registry = _audioSubscribers;
      name = 'audio';
    } else if (args.characteristic.uuid == _telemetryChar.uuid) {
      registry = _telemetrySubscribers;
      name = 'telemetry';
    } else {
      return;
    }
    if (args.state) {
      registry[id] = args.central;
    } else {
      registry.remove(id);
    }
    _logActivity(
        '${_shortId(args.central)} ${args.state ? 'subscribed to' : 'unsubscribed from'} $name');
    notifyListeners();
  }

  Future<void> _onReadRequested(
      GATTCharacteristicReadRequestedEventArgs args) async {
    if (args.characteristic.uuid != _telemetryChar.uuid) {
      await _peripheral.respondReadRequestWithError(args.request,
          error: GATTError.readNotPermitted);
      return;
    }
    final frame = BatteryStatusMessage(
      sequence: _telemetrySeq.next(),
      percent: _batteryPercent,
      charging: _batteryCharging,
      millivolts: _batteryMillivolts,
    ).encode();
    // Long-read support: respond with the remainder from the offset.
    final value = args.request.offset == 0
        ? frame
        : Uint8List.sublistView(frame, args.request.offset);
    await _peripheral.respondReadRequestWithValue(args.request, value: value);
    _logActivity('${_shortId(args.central)} read battery');
  }

  Future<void> _onWriteRequested(
      GATTCharacteristicWriteRequestedEventArgs args) async {
    final request = args.request;
    if (request.offset != 0) {
      // Prepared/long writes are not part of the contract: every frame
      // fits a normal write at the MTU the companion negotiates.
      Log.w(_tag, 'rejecting prepared write (offset ${request.offset})');
      await _peripheral.respondWriteRequestWithError(request,
          error: GATTError.requestNotSupported);
      return;
    }

    final BotMessage message;
    try {
      message = BotMessage.decode(request.value);
    } on ProtocolException catch (e) {
      // Malformed radio input is logged and dropped, never fatal.
      Log.w(_tag, 'dropping malformed frame: $e');
      _logActivity('Malformed frame dropped ($e)');
      await _peripheral.respondWriteRequestWithError(request,
          error: GATTError.unlikelyError);
      notifyListeners();
      return;
    }

    if (args.characteristic.uuid == _audioToBotChar.uuid &&
        message is AudioChunkMessage) {
      _onAudioIn(message);
    } else if (args.characteristic.uuid == _controlChar.uuid &&
        message is ControlMessage) {
      await _onControl(message, args.central);
    } else {
      Log.w(_tag,
          'wrong message type 0x${message.header.type.toRadixString(16)} for characteristic ${args.characteristic.uuid}');
      await _peripheral.respondWriteRequestWithError(request,
          error: GATTError.requestNotSupported);
      return;
    }

    await _peripheral.respondWriteRequest(request);
    notifyListeners();
  }

  // --- audio in (phone -> bot speaker) ---

  void _onAudioIn(AudioChunkMessage message) {
    if (message.isUtteranceStart) {
      receivingAudio = true;
      audioFramesReceived = 0;
      audioFramesLost = 0;
      lastAudioSequence = message.sequence - 1;
      _setBotState(BotState.speaking);
    }

    if (message.adpcmBlock.isNotEmpty) {
      audioFramesReceived += 1;
      final expected = (lastAudioSequence + 1) & FrameHeader.maxSequence;
      if (message.sequence != expected) {
        final gap =
            (message.sequence - expected) & FrameHeader.maxSequence;
        audioFramesLost += gap;
        Log.w(_tag, 'audio gap: expected seq $expected got ${message.sequence}');
      }
      lastAudioSequence = message.sequence;

      if (_playbackReady) {
        final samples = decodeAdpcmBlock(message.adpcmBlock);
        // Fire and forget; playback latency accounting comes with M1.
        unawaited(FlutterPcmSound.feed(PcmArrayInt16.fromList(samples)));
      }
    }

    if (message.isUtteranceEnd) {
      receivingAudio = false;
      _logActivity(
          'Utterance played: $audioFramesReceived frames, $audioFramesLost lost');
      _setBotState(BotState.idle);
    }
  }

  // --- control (phone -> bot actuators) ---

  Future<void> _onControl(ControlMessage message, Central central) async {
    switch (message) {
      case SetLedCommand(:final red, :final green, :final blue, :final pattern):
        ledRed = red;
        ledGreen = green;
        ledBlue = blue;
        ledPattern = pattern;
        _logActivity('set_led rgb($red,$green,$blue) ${pattern.name}');
      case WiggleCommand():
        wiggleCount += 1;
        _logActivity('wiggle');
      case PlaySoundCommand(:final sound):
        _logActivity('play_sound ${sound.name}');
        _playCannedSound(sound);
      case GetBatteryCommand():
        _logActivity('get_battery -> $_batteryPercent%');
        await _notifyTelemetry(BatteryStatusMessage(
          sequence: _telemetrySeq.next(),
          percent: _batteryPercent,
          charging: _batteryCharging,
          millivolts: _batteryMillivolts,
        ));
      case ShowTextCommand(:final utf8Text, :final isFinal):
        _onShowText(utf8Text, isFinal: isFinal);
    }
  }

  void _onShowText(Uint8List utf8Text, {required bool isFinal}) {
    final text = utf8.decode(utf8Text, allowMalformed: true);
    final last = conversation.isEmpty ? null : conversation.last;
    if (last != null &&
        last.role == SimulatorChatRole.bot &&
        last.streaming) {
      last.text = text.isEmpty ? last.text : text;
      last.streaming = !isFinal;
    } else if (text.isNotEmpty) {
      _appendChat(SimulatorChatRole.bot, text, streaming: !isFinal);
    }
    if (isFinal && text.isNotEmpty) {
      _logActivity('bot: $text');
    }
  }

  /// Stand-in for the ESP32's canned sound set: a short synthesized tone
  /// per sound so the human test is audible.
  void _playCannedSound(BotSound sound) {
    if (!_playbackReady) return;
    final frequency = switch (sound) {
      BotSound.chirp => 1800.0,
      BotSound.beep => 1000.0,
      BotSound.purr => 220.0,
      BotSound.alarm => 660.0,
    };
    const durationMs = 250;
    const sampleRate = AudioWireFormat.sampleRate;
    final sampleCount = sampleRate * durationMs ~/ 1000;
    final samples = Int16List(sampleCount);
    var phase = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      // Fade in/out to avoid clicks.
      final envelope = i < 400
          ? i / 400
          : (i > sampleCount - 400 ? (sampleCount - i) / 400 : 1.0);
      samples[i] = (10000 * envelope * math.sin(phase)).round();
      phase += 2 * math.pi * frequency / sampleRate;
    }
    unawaited(FlutterPcmSound.feed(PcmArrayInt16.fromList(samples)));
  }

  // --- push-to-talk (bot mic -> phone) ---

  Future<void> startTalking() async {
    if (talking) return;
    if (_audioSubscribers.isEmpty) {
      _logActivity('No audio subscriber; not recording');
      return;
    }
    if (!await _recorder.hasPermission()) {
      _logActivity('Mic permission denied');
      Log.e(_tag, 'RECORD_AUDIO permission denied');
      notifyListeners();
      return;
    }

    talking = true;
    micFramesSent = 0;
    _micPending.clear();
    _micEncoder.reset();
    _micChecksum.reset();
    _micUtteranceStarted = false;
    _audioOutSeq.reset();
    _appendChat(SimulatorChatRole.user, '…', streaming: true);
    notifyListeners();

    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: AudioWireFormat.sampleRate,
        numChannels: AudioWireFormat.channels,
        echoCancel: true,
        autoGain: true,
      ));
      _micSubscription = stream.listen(_onMicChunk,
          onError: (Object e) => Log.e(_tag, 'mic stream error', e));
      _setBotState(BotState.listening);
      Log.i(_tag, 'mic streaming started');
    } catch (e) {
      talking = false;
      _finishUserChatLine('mic failed');
      _logActivity('Mic start failed: $e');
      Log.e(_tag, 'failed to start mic stream', e);
      notifyListeners();
    }
  }

  void _onMicChunk(Uint8List chunk) {
    _micPending.add(chunk);
    const frameBytes = AudioWireFormat.samplesPerFrame * 2; // PCM16
    if (_micPending.length < frameBytes) return;

    final buffered = _micPending.takeBytes();
    var offset = 0;
    while (buffered.length - offset >= frameBytes) {
      final pcm = pcm16BytesToSamples(
          Uint8List.sublistView(buffered, offset, offset + frameBytes));
      offset += frameBytes;
      _sendAudioFrame(
        _micEncoder.encodeBlock(pcm),
        isStart: !_micUtteranceStarted,
        isEnd: false,
      );
      _micUtteranceStarted = true;
    }
    if (offset < buffered.length) {
      _micPending.add(Uint8List.sublistView(buffered, offset));
    }
  }

  Future<void> stopTalking() => _stopTalkingInternal(notifyPeers: true);

  Future<void> _stopTalkingInternal({required bool notifyPeers}) async {
    if (!talking) return;
    talking = false;
    await _micSubscription?.cancel();
    _micSubscription = null;
    try {
      await _recorder.stop();
    } catch (e) {
      Log.w(_tag, 'recorder stop failed: $e');
    }
    if (notifyPeers && _micUtteranceStarted) {
      // Empty end-of-stream frame closes the utterance (protocol contract).
      _sendAudioFrame(Uint8List(0), isStart: false, isEnd: true);
      _logActivity(
          'Utterance sent: $micFramesSent frames, crc ${_micChecksum.hex}');
    }
    final audioMs = micFramesSent * AudioWireFormat.millisPerFrame;
    final seconds = (audioMs / 1000).toStringAsFixed(1);
    _finishUserChatLine(notifyPeers && _micUtteranceStarted
        ? 'spoke $seconds s'
        : 'spoke (not sent)');
    _setBotState(BotState.idle);
    Log.i(_tag,
        'mic streaming stopped, $micFramesSent frames sent, crc ${_micChecksum.hex}');
    notifyListeners();
  }

  void _sendAudioFrame(Uint8List block,
      {required bool isStart, required bool isEnd}) {
    _micChecksum.add(block);
    final frame = AudioChunkMessage(
      sequence: _audioOutSeq.next(),
      adpcmBlock: block,
      isUtteranceStart: isStart,
      isUtteranceEnd: isEnd,
    ).encode();
    for (final central in _audioSubscribers.values) {
      unawaited(_peripheral
          .notifyCharacteristic(central, _audioFromBotChar, value: frame)
          .catchError((Object e) {
        // Typical cause: central's MTU too small for a 168-byte frame.
        Log.w(_tag, 'notify failed for ${_shortId(central)}: $e');
      }));
    }
    micFramesSent += 1;
    if (micFramesSent % 25 == 0) notifyListeners(); // ~every 500 ms
  }

  // --- telemetry / state ---

  Future<void> _notifyTelemetry(BotMessage message) async {
    final frame = message.encode();
    for (final central in _telemetrySubscribers.values) {
      try {
        await _peripheral.notifyCharacteristic(central, _telemetryChar,
            value: frame);
      } catch (e) {
        Log.w(_tag, 'telemetry notify failed for ${_shortId(central)}: $e');
      }
    }
  }

  void _setBotState(BotState state) {
    if (botState == state) return;
    botState = state;
    unawaited(_notifyTelemetry(
        BotStateMessage(sequence: _telemetrySeq.next(), state: state)));
    notifyListeners();
  }

  // --- misc ---

  void _appendChat(SimulatorChatRole role, String text,
      {bool streaming = false}) {
    conversation.add(SimulatorChatLine(
      role: role,
      text: text,
      streaming: streaming,
    ));
    if (conversation.length > _maxChatLines) {
      conversation.removeRange(0, conversation.length - _maxChatLines);
    }
  }

  void _finishUserChatLine(String text) {
    final last = conversation.isEmpty ? null : conversation.last;
    if (last != null &&
        last.role == SimulatorChatRole.user &&
        last.streaming) {
      last.text = text;
      last.streaming = false;
    } else {
      _appendChat(SimulatorChatRole.user, text);
    }
  }

  void _logActivity(String message) {
    activityLog.insert(0, SimulatorLogEntry(message));
    if (activityLog.length > _maxLogEntries) {
      activityLog.removeRange(_maxLogEntries, activityLog.length);
    }
    notifyListeners();
  }

  String _shortId(Central central) {
    final id = central.uuid.toString();
    return id.length > 8 ? id.substring(id.length - 8) : id;
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    // Teardown is async and may fire state changes after dispose.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }

  Future<void> _teardown() async {
    await _stopTalkingInternal(notifyPeers: false);
    for (final sub in _bleSubscriptions) {
      await sub.cancel();
    }
    try {
      await _peripheral.stopAdvertising();
      await _peripheral.removeAllServices();
    } catch (e) {
      Log.w(_tag, 'teardown: $e');
    }
    await _recorder.dispose();
    if (_playbackReady) {
      await FlutterPcmSound.release();
    }
  }
}
