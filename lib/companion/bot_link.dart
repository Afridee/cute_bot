// BLE central link to the bot (M1). Owns the whole connection lifecycle:
//
// - scan for the bot service UUID, connect to the first match
// - negotiate MTU immediately on connect (request 517, accept less)
// - discover GATT, subscribe to audio + telemetry notifications
// - auto-reconnect on drop with exponential backoff (rescan, because
//   Android peripherals rotate their random address, so a remembered
//   handle can go stale)
// - prioritized write queue: control commands always jump ahead of queued
//   audio frames ("set_led must not sit behind a queue of audio chunks")
//
// Failure paths handled: Bluetooth off/on, permission denied, connect
// timeout, characteristic discovery mismatch, writes failing mid-flight.

import 'dart:async';
import 'dart:collection';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../shared/ble_protocol.dart';
import '../shared/log.dart';

const String _tag = 'BotLink';

/// Companion-side connection lifecycle.
enum BotLinkState {
  /// Not started, or stopped.
  idle,

  /// Bluetooth radio is off; waiting for it to come back.
  bluetoothOff,

  /// BLE permissions denied. Terminal until the user grants them.
  unauthorized,

  /// This device cannot do BLE central. Terminal.
  unsupported,

  /// Scanning for the bot service UUID.
  scanning,

  /// Found the bot; GATT connection in progress.
  connecting,

  /// Connected; negotiating MTU and discovering characteristics.
  configuring,

  /// Fully up: subscribed and ready for audio + control traffic.
  ready,

  /// Link dropped; waiting out the backoff delay before rescanning.
  reconnectWait,
}

/// A queued control write, completed when the peripheral acks it.
final class _ControlWrite {
  _ControlWrite(this.frame);
  final Uint8List frame;
  final Completer<void> completer = Completer<void>();
}

final class BotLink extends ChangeNotifier {
  BotLink() : _central = CentralManager();

  final CentralManager _central;

  // --- state surfaced to the UI ---

  BotLinkState state = BotLinkState.idle;
  BluetoothLowEnergyState radioState = BluetoothLowEnergyState.unknown;

  /// Negotiated ATT MTU (23 until proven otherwise).
  int mtu = 23;

  /// Short id of the connected bot, for display.
  String? botId;
  int? rssi;

  /// Consecutive failed connection attempts (drives the backoff).
  int reconnectAttempt = 0;

  /// When the next reconnect fires, for the debug panel countdown.
  DateTime? nextReconnectAt;

  String? lastError;

  /// Audio frames dropped because the outbound queue overflowed.
  int audioFramesDroppedOnSend = 0;

  // --- inbound message streams ---

  final _audioController = StreamController<AudioChunkMessage>.broadcast();
  final _telemetryController = StreamController<BotMessage>.broadcast();

  /// Bot mic audio (already protocol-decoded), straight off the radio.
  Stream<AudioChunkMessage> get audioFromBot => _audioController.stream;

  /// Battery and bot-state messages.
  Stream<BotMessage> get telemetry => _telemetryController.stream;

  // --- internals ---

  final List<StreamSubscription> _subscriptions = [];
  Peripheral? _peripheral;
  GATTCharacteristic? _audioFromBotChar;
  GATTCharacteristic? _audioToBotChar;
  GATTCharacteristic? _controlChar;
  GATTCharacteristic? _telemetryChar;

  Timer? _reconnectTimer;
  Timer? _connectTimeout;
  bool _started = false;
  bool _stopping = false;

  static const Duration _connectTimeoutDuration = Duration(seconds: 15);
  static const Duration _maxBackoff = Duration(seconds: 30);

  /// Outbound queues. Control jumps ahead of audio, always.
  final Queue<_ControlWrite> _controlQueue = Queue();
  final Queue<Uint8List> _audioQueue = Queue();

  /// Bound on queued audio: 256 frames ≈ 5 s of speech. Beyond that the
  /// link is too slow anyway; dropping oldest keeps latency bounded.
  static const int _maxQueuedAudioFrames = 256;

  bool _pumping = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _subscriptions.add(_central.stateChanged.listen(_onRadioState));
    _subscriptions.add(_central.discovered.listen(_onDiscovered));
    _subscriptions
        .add(_central.connectionStateChanged.listen(_onConnectionState));
    _subscriptions.add(_central.mtuChanged.listen((e) {
      if (e.peripheral.uuid != _peripheral?.uuid) return;
      mtu = e.mtu;
      Log.i(_tag, 'MTU changed: ${e.mtu}');
      notifyListeners();
    }));
    _subscriptions.add(_central.characteristicNotified.listen(_onNotified));

    _onRadioState(BluetoothLowEnergyStateChangedEventArgs(_central.state));
  }

  Future<void> _onRadioState(
      BluetoothLowEnergyStateChangedEventArgs args) async {
    radioState = args.state;
    Log.i(_tag, 'radio state: ${args.state.name}');

    switch (args.state) {
      case BluetoothLowEnergyState.unauthorized:
        final granted = await _central.authorize();
        if (!granted) {
          state = BotLinkState.unauthorized;
          lastError = 'Bluetooth permission denied. Grant it in settings.';
          Log.e(_tag, 'BLE permissions denied');
        }
        // If granted, a poweredOn state event follows and starts the scan.
      case BluetoothLowEnergyState.poweredOn:
        lastError = null;
        if (state != BotLinkState.ready &&
            state != BotLinkState.connecting &&
            state != BotLinkState.configuring) {
          await _startScan();
        }
      case BluetoothLowEnergyState.poweredOff:
        // Radio gone: everything session-scoped is dead. We rescan when
        // it comes back.
        _cancelTimers();
        _dropSession();
        state = BotLinkState.bluetoothOff;
      case BluetoothLowEnergyState.unsupported:
        state = BotLinkState.unsupported;
        lastError = 'This device does not support BLE central mode.';
      case BluetoothLowEnergyState.unknown:
        break;
    }
    notifyListeners();
  }

  // --- scan / connect / reconnect ---

  Future<void> _startScan() async {
    if (_stopping) return;
    try {
      await _central.startDiscovery(
        serviceUUIDs: [UUID.fromString(BotUuids.service)],
      );
      state = BotLinkState.scanning;
      Log.i(_tag, 'scanning for ${BotUuids.service}');
    } catch (e) {
      // Typical cause: scan requested while the radio is settling. Retry
      // through the normal backoff path.
      lastError = 'Scan failed: $e';
      Log.e(_tag, 'startDiscovery failed', e);
      _scheduleReconnect();
    }
    notifyListeners();
  }

  Future<void> _onDiscovered(DiscoveredEventArgs args) async {
    if (state != BotLinkState.scanning) return;
    state = BotLinkState.connecting;
    _peripheral = args.peripheral;
    rssi = args.rssi;
    botId = _shortId(args.peripheral.uuid.toString());
    Log.i(_tag,
        'found bot $botId (rssi ${args.rssi}, name ${args.advertisement.name})');
    notifyListeners();

    try {
      await _central.stopDiscovery();
    } catch (e) {
      Log.w(_tag, 'stopDiscovery failed: $e');
    }

    _connectTimeout = Timer(_connectTimeoutDuration, () async {
      Log.w(_tag, 'connect timed out after $_connectTimeoutDuration');
      lastError = 'Connect timed out';
      try {
        await _central.disconnect(_peripheral!);
      } catch (_) {}
      _scheduleReconnect();
    });

    try {
      await _central.connect(args.peripheral);
      // Success path continues in _onConnectionState(connected).
    } catch (e) {
      _connectTimeout?.cancel();
      lastError = 'Connect failed: $e';
      Log.e(_tag, 'connect failed', e);
      _scheduleReconnect();
    }
  }

  Future<void> _onConnectionState(
      PeripheralConnectionStateChangedEventArgs args) async {
    if (args.peripheral.uuid != _peripheral?.uuid) return;

    if (args.state == ConnectionState.connected) {
      _connectTimeout?.cancel();
      await _configure();
    } else {
      final wasReady = state == BotLinkState.ready;
      Log.w(_tag, 'disconnected (was ${state.name})');
      _dropSession();
      if (_stopping) return;
      if (wasReady) {
        // Clean drop after a good session: retry quickly from attempt 0.
        reconnectAttempt = 0;
      }
      _scheduleReconnect();
    }
  }

  /// Connected -> negotiate MTU, discover GATT, subscribe. Any failure here
  /// tears the session down and goes through reconnect.
  Future<void> _configure() async {
    final peripheral = _peripheral!;
    state = BotLinkState.configuring;
    notifyListeners();

    try {
      // MTU first, before any traffic (milestone requirement). Android 14+
      // may auto-negotiate 517 and disregard this; the return value is the
      // real negotiated MTU either way.
      try {
        mtu = await _central.requestMTU(peripheral, mtu: kPreferredMtu);
        Log.i(_tag, 'negotiated MTU $mtu');
      } catch (e) {
        // Not fatal: proceed at whatever the default is; the chunker
        // adapts frame size to `mtu`.
        Log.w(_tag, 'requestMTU failed, staying at $mtu: $e');
      }

      final services = await _central.discoverGATT(peripheral);
      final service = services.firstWhere(
        (s) => s.uuid == UUID.fromString(BotUuids.service),
        orElse: () => throw StateError('bot service missing after connect'),
      );
      GATTCharacteristic find(String uuid) => service.characteristics
          .firstWhere((c) => c.uuid == UUID.fromString(uuid),
              orElse: () =>
                  throw StateError('characteristic $uuid missing'));
      _audioFromBotChar = find(BotUuids.audioFromBot);
      _audioToBotChar = find(BotUuids.audioToBot);
      _controlChar = find(BotUuids.control);
      _telemetryChar = find(BotUuids.telemetry);

      await _central.setCharacteristicNotifyState(
          peripheral, _audioFromBotChar!,
          state: true);
      await _central.setCharacteristicNotifyState(peripheral, _telemetryChar!,
          state: true);

      try {
        rssi = await _central.readRSSI(peripheral);
      } catch (_) {} // display-only, ignore

      state = BotLinkState.ready;
      reconnectAttempt = 0;
      nextReconnectAt = null;
      lastError = null;
      Log.i(_tag, 'link ready (MTU $mtu)');
      notifyListeners();
      _pump();
    } catch (e) {
      lastError = 'Setup failed: $e';
      Log.e(_tag, 'configure failed', e);
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
      _dropSession();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_stopping || radioState != BluetoothLowEnergyState.poweredOn) return;
    _cancelTimers();

    // 0.5s, 1s, 2s, 4s ... capped at 30s.
    final millis = 500 * (1 << reconnectAttempt.clamp(0, 10));
    final delay = millis > _maxBackoff.inMilliseconds
        ? _maxBackoff
        : Duration(milliseconds: millis);
    reconnectAttempt += 1;
    nextReconnectAt = DateTime.now().add(delay);
    state = BotLinkState.reconnectWait;
    Log.i(_tag, 'reconnect attempt $reconnectAttempt in $delay');
    notifyListeners();

    _reconnectTimer = Timer(delay, () {
      nextReconnectAt = null;
      _startScan();
    });
  }

  /// Clears connection-scoped state and fails anything still queued.
  void _dropSession() {
    _connectTimeout?.cancel();
    _peripheral = null;
    _audioFromBotChar = null;
    _audioToBotChar = null;
    _controlChar = null;
    _telemetryChar = null;
    botId = null;
    rssi = null;
    mtu = 23;
    if (state == BotLinkState.ready ||
        state == BotLinkState.connecting ||
        state == BotLinkState.configuring) {
      state = BotLinkState.idle;
    }
    _audioQueue.clear();
    while (_controlQueue.isNotEmpty) {
      _controlQueue
          .removeFirst()
          .completer
          .completeError(StateError('link dropped'));
    }
    notifyListeners();
  }

  void _cancelTimers() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectTimeout?.cancel();
    _connectTimeout = null;
    nextReconnectAt = null;
  }

  // --- inbound notifications ---

  void _onNotified(GATTCharacteristicNotifiedEventArgs args) {
    if (args.peripheral.uuid != _peripheral?.uuid) return;

    final BotMessage message;
    try {
      message = BotMessage.decode(args.value);
    } on ProtocolException catch (e) {
      // Malformed radio input is logged and dropped, never fatal.
      Log.w(_tag, 'dropping malformed frame: $e');
      return;
    }

    if (args.characteristic.uuid == _audioFromBotChar?.uuid &&
        message is AudioChunkMessage) {
      _audioController.add(message);
    } else if (args.characteristic.uuid == _telemetryChar?.uuid) {
      _telemetryController.add(message);
    } else {
      Log.w(_tag,
          'unexpected message type 0x${message.header.type.toRadixString(16)} on ${args.characteristic.uuid}');
    }
  }

  // --- outbound writes (prioritized) ---

  /// Queues a control command ahead of any audio. Completes when the bot
  /// acks the write (control uses write-with-response).
  Future<void> sendControl(ControlMessage message) {
    if (state != BotLinkState.ready) {
      return Future.error(StateError('not connected'));
    }
    final write = _ControlWrite(message.encode());
    _controlQueue.add(write);
    _pump();
    return write.completer.future;
  }

  /// Queues one audio frame (fire-and-forget, write-without-response).
  /// Frames beyond the queue bound drop oldest-first to keep latency sane.
  void sendAudioFrame(AudioChunkMessage message) {
    if (state != BotLinkState.ready) return;
    _audioQueue.add(message.encode());
    while (_audioQueue.length > _maxQueuedAudioFrames) {
      _audioQueue.removeFirst();
      audioFramesDroppedOnSend += 1;
    }
    _pump();
  }

  /// Frames currently waiting to go out (for the debug panel).
  int get queuedAudioFrames => _audioQueue.length;

  /// Single writer loop. BLE GATT operations must be serialized; this is
  /// the only place that calls writeCharacteristic.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (state == BotLinkState.ready &&
          (_controlQueue.isNotEmpty || _audioQueue.isNotEmpty)) {
        final peripheral = _peripheral;
        if (peripheral == null) break;

        if (_controlQueue.isNotEmpty) {
          final write = _controlQueue.removeFirst();
          try {
            await _central.writeCharacteristic(peripheral, _controlChar!,
                value: write.frame,
                type: GATTCharacteristicWriteType.withResponse);
            write.completer.complete();
          } catch (e) {
            Log.e(_tag, 'control write failed', e);
            write.completer.completeError(e);
          }
        } else {
          final frame = _audioQueue.removeFirst();
          try {
            await _central.writeCharacteristic(peripheral, _audioToBotChar!,
                value: frame,
                type: GATTCharacteristicWriteType.withoutResponse);
          } catch (e) {
            // One lost audio frame is 20 ms of speech; log and move on.
            Log.w(_tag, 'audio write failed: $e');
          }
        }
      }
    } finally {
      _pumping = false;
    }
  }

  // --- teardown ---

  String _shortId(String id) =>
      id.length > 8 ? id.substring(id.length - 8) : id;

  bool _disposed = false;

  @override
  void notifyListeners() {
    // Teardown is async and may fire state changes after dispose.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopping = true;
    unawaited(_teardown());
    super.dispose();
  }

  Future<void> _teardown() async {
    _cancelTimers();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    final peripheral = _peripheral;
    if (peripheral != null) {
      try {
        await _central.disconnect(peripheral);
      } catch (e) {
        Log.w(_tag, 'disconnect during teardown: $e');
      }
    }
    _dropSession();
    await _audioController.close();
    await _telemetryController.close();
  }
}
