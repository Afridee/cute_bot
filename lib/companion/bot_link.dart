// BLE central link to the bot (M1). Owns the whole connection lifecycle:
//
// - scan for the bot service UUID, connect to the first match
// - discover GATT, subscribe to audio + telemetry notifications, then
//   negotiate MTU (CCCD writes after MTU 517 hang on some Android OEM stacks)
// - auto-reconnect on drop with exponential backoff (rescan, because
//   Android peripherals rotate their random address, so a remembered
//   handle can go stale)
// - prioritized write queue: control commands always jump ahead of queued
//   audio frames ("set_led must not sit behind a queue of audio chunks")
//
// Failure paths handled: Bluetooth off/on, permission denied, connect
// timeout, GATT establish failure (Android status 62), characteristic
// discovery mismatch, writes failing mid-flight.

import 'dart:async';
import 'dart:collection';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../shared/ble_protocol.dart';
import '../shared/log.dart';

const String _tag = 'BotLink';

/// Short UI string for a BLE plugin/platform failure. The raw exception
/// is often a Java stack wrapped in a platform exception; dumping that
/// on screen looks like a crash.
String bleFailureMessage(String action, Object error) {
  final status = bleGattStatus(error);
  const retry = 'Retrying…';
  return switch (status) {
    // 0x08 GATT_CONN_TIMEOUT, 0x3E GATT_CONN_FAIL_ESTABLISH / LMP timeout.
    8 || 62 => 'Couldn\'t reach the bot. $retry',
    // 0x85 GATT_ERROR — Android's generic BLE failure.
    133 => 'Android BLE stack error. $retry',
    // 0x13 remote terminated, 0x16 local host terminated.
    19 => 'Bot closed the link. $retry',
    22 => 'Phone closed the link. $retry',
    _ when status != null => '$action failed (status $status). $retry',
    _ when error is TimeoutException => 'Bot didn\'t confirm setup. $retry',
    _ => '$action failed. $retry',
  };
}

/// One-line log form of a BLE plugin exception. Never includes the Java stack.
String bleLogDetail(Object error) {
  final status = bleGattStatus(error);
  if (status != null) return 'GATT status $status';
  final first = error.toString().split('\n').first.trim();
  return first.length > 160 ? '${first.substring(0, 157)}...' : first;
}

int? bleGattStatus(Object error) {
  final match = RegExp(r'status:\s*(\d+)').firstMatch(error.toString());
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

bool bleConnectIsRetryable(Object error) {
  final status = bleGattStatus(error);
  return status == 8 || status == 62 || status == 133;
}

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

/// A scan that reports success but never delivers a result — common after
/// the service isolate is freshly spawned — should be cycled. Stay under
/// Android's 5 startScan / 30 s cap: one refresh per this window is fine.
const Duration kScanStaleAfter = Duration(seconds: 25);

/// Whether a running scan has gone quiet long enough to restart.
@visibleForTesting
bool shouldRefreshStaleScan({
  required BotLinkState state,
  required DateTime? scanningSince,
  required DateTime now,
  Duration staleAfter = kScanStaleAfter,
}) {
  if (state != BotLinkState.scanning || scanningSince == null) return false;
  return now.difference(scanningSince) >= staleAfter;
}

/// startDiscovery's Future completes when the scanner starts, but an
/// advertisement can already have been delivered. Do not take (or fail)
/// the scanning state if a connect is already in flight.
@visibleForTesting
bool shouldAdoptScanningState(BotLinkState state) {
  return state != BotLinkState.connecting &&
      state != BotLinkState.configuring &&
      state != BotLinkState.ready;
}

/// A queued control write, completed when the peripheral acks it.
final class _ControlWrite {
  _ControlWrite(this.frame);
  final Uint8List frame;
  final Completer<void> completer = Completer<void>();
}

final class BotLink extends ChangeNotifier {
  BotLink({this.canRequestPermissions = true}) : _central = CentralManager();

  final CentralManager _central;

  /// Whether this isolate can show the OS permission dialog. False in the
  /// foreground service isolate: the BLE plugin's authorize() needs an
  /// Activity, which a background engine never has (verified against
  /// bluetooth_low_energy_android 6.2.1 — everything else in the central
  /// path is Context-only). Permission granting is the UI's job, before the
  /// service starts.
  final bool canRequestPermissions;

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
  DateTime? _scanningSince;
  bool _started = false;
  bool _stopping = false;

  /// True while [connect] is in flight (including retries). The plugin
  /// emits a disconnected event for every failed connectGatt; those must
  /// not tear the session down or we cannot retry the same peripheral.
  bool _establishing = false;

  static const Duration _connectTimeoutDuration = Duration(seconds: 15);
  static const Duration _maxBackoff = Duration(seconds: 30);

  /// Used after stopScan on connect retry #2. Attempt 1 connects *while*
  /// still scanning so the controller can hear the next advertisement.
  static const Duration _postScanSettle = Duration(milliseconds: 400);

  /// After MTU, Android often fires onServiceChanged and returns an empty
  /// GATT cache if we discover immediately. Give the cache a beat.
  static const Duration _postMtuSettle = Duration(milliseconds: 400);

  /// After discoverServices, the stack updates the connection interval
  /// (7.5 ms → 30 ms) and PHY (1M → 2M). A CCCD write issued during that
  /// window is silently dropped; Android then ATT-times-out (~30 s) and
  /// locally disconnects with status 22, which the plugin reports as 133.
  static const Duration _postDiscoverSettle = Duration(milliseconds: 1500);

  /// Fail a hung notify-enable before the stack's 30 s ATT timeout.
  static const Duration _notifyTimeout = Duration(seconds: 8);

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

    _listen(_central.stateChanged, _onRadioState);
    _listen(_central.discovered, _onDiscovered);
    _listen(_central.connectionStateChanged, _onConnectionState);
    _listen(_central.mtuChanged, (e) async {
      if (e.peripheral.uuid != _peripheral?.uuid) return;
      mtu = e.mtu;
      Log.i(_tag, 'MTU changed: ${e.mtu}');
      notifyListeners();
    });
    _listen(_central.characteristicNotified, _onNotified);

    _onRadioState(BluetoothLowEnergyStateChangedEventArgs(_central.state));
  }

  /// Service heartbeat. Cycles a scan that has gone quiet so a freshly
  /// spawned isolate cannot sit on a scanner that reports success but
  /// never delivers the bot's advertisements.
  void onHeartbeat() {
    if (!shouldRefreshStaleScan(
      state: state,
      scanningSince: _scanningSince,
      now: DateTime.now(),
    )) {
      return;
    }
    Log.i(_tag, 'scan refresh (quiet for $kScanStaleAfter)');
    unawaited(_refreshScan());
  }

  Future<void> _refreshScan() async {
    if (_stopping || state != BotLinkState.scanning) return;
    _scanningSince = DateTime.now();
    try {
      await _central.stopDiscovery();
    } catch (e) {
      Log.w(_tag, 'scan refresh stopDiscovery: ${bleLogDetail(e)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (_stopping || state != BotLinkState.scanning) return;
    await _startScan();
  }

  /// BLE plugin streams must not crash the service isolate. Async handlers
  /// are not awaited by [Stream.listen], so errors would otherwise become
  /// unhandled (Flutter's red error screen in the UI isolate, or a dead
  /// service).
  void _listen<T>(Stream<T> stream, FutureOr<void> Function(T) onEvent) {
    _subscriptions.add(stream.listen(
      (event) {
        Future<void> run() async {
          try {
            await onEvent(event);
          } catch (e, st) {
            Log.e(_tag, 'BLE event handler failed (${bleLogDetail(e)})', null, st);
          }
        }

        unawaited(run());
      },
      onError: (Object e, StackTrace st) {
        Log.e(_tag, 'BLE stream error (${bleLogDetail(e)})', null, st);
      },
    ));
  }

  Future<void> _onRadioState(
      BluetoothLowEnergyStateChangedEventArgs args) async {
    radioState = args.state;
    Log.i(_tag, 'radio state: ${args.state.name}');

    switch (args.state) {
      case BluetoothLowEnergyState.unauthorized:
        if (!canRequestPermissions) {
          // Service isolate: no Activity, no dialog. Surface the state and
          // wait — the UI grants and the radio re-announces poweredOn.
          state = BotLinkState.unauthorized;
          lastError = 'Bluetooth permission missing. Open the app to grant.';
          Log.w(_tag, 'unauthorized in a no-permission-request context');
          break;
        }
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
      if (_stopping || !shouldAdoptScanningState(state)) return;
      state = BotLinkState.scanning;
      _scanningSince = DateTime.now();
      Log.i(_tag, 'scanning for ${BotUuids.service}');
    } catch (e) {
      // Typical cause: scan requested while the radio is settling. Retry
      // through the normal backoff path. A result can also land before
      // this Future completes — don't bounce a live connect into backoff.
      if (_stopping || !shouldAdoptScanningState(state)) return;
      lastError = bleFailureMessage('Scan', e);
      Log.e(_tag, 'startDiscovery failed (${bleLogDetail(e)})');
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

    _establishing = true;
    try {
      await _connectWithRetries(args.peripheral);
    } finally {
      _establishing = false;
    }
  }

  /// Phone-to-phone BLE often fails the first `connectGatt` with status 62
  /// (HCI connection failed to establish). Attempt 1 keeps the scan running
  /// so the controller can still hear advertisements; later attempts stop
  /// the scan (the other classic Android workaround) and retry in place
  /// before falling back to a full rescan.
  Future<void> _connectWithRetries(Peripheral peripheral) async {
    const maxAttempts = 3;
    Object? lastFailure;

    _connectTimeout = Timer(_connectTimeoutDuration, () async {
      Log.w(_tag, 'connect timed out after $_connectTimeoutDuration');
      lastError = 'Connect timed out. Retrying…';
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
      _dropSession();
      _scheduleReconnect();
    });

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_stopping || state != BotLinkState.connecting) return;

      if (attempt == 2) {
        try {
          await _central.stopDiscovery();
        } catch (e) {
          Log.w(_tag, 'stopDiscovery failed: ${bleLogDetail(e)}');
        }
        await Future<void>.delayed(_postScanSettle);
        if (_stopping || state != BotLinkState.connecting) return;
      } else if (attempt > 2) {
        try {
          await _central.disconnect(peripheral);
        } catch (_) {}
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt - 1)));
        if (_stopping || state != BotLinkState.connecting) return;
      }

      try {
        Log.i(_tag, 'connect attempt $attempt/$maxAttempts');
        await _central.connect(peripheral);
        // Success path continues in _onConnectionState(connected).
        return;
      } catch (e) {
        lastFailure = e;
        Log.w(_tag,
            'connect attempt $attempt/$maxAttempts failed (${bleLogDetail(e)})');
        if (attempt == maxAttempts || !bleConnectIsRetryable(e)) break;
      }
    }

    _connectTimeout?.cancel();
    lastError = bleFailureMessage('Connect', lastFailure ?? 'unknown');
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    _dropSession();
    _scheduleReconnect();
  }

  Future<void> _onConnectionState(
      PeripheralConnectionStateChangedEventArgs args) async {
    if (args.peripheral.uuid != _peripheral?.uuid) return;

    if (args.state == ConnectionState.connected) {
      _connectTimeout?.cancel();
      if (state == BotLinkState.configuring || state == BotLinkState.ready) {
        return;
      }
      try {
        await _central.stopDiscovery();
      } catch (_) {}
      await _configure();
    } else {
      // Failed connectGatt emits disconnected; retries handle that.
      if (_establishing) return;
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

  /// Connected -> discover GATT, subscribe, then raise MTU. Any failure here
  /// tears the session down and goes through reconnect.
  ///
  /// CCCD (notify enable) is written *before* requestMTU. On this Vivo
  /// Android 16 stack, writing the 2-byte CCCD after MTU 517 never gets
  /// `onDescriptorWrite` and the plugin hangs until ATT timeout.
  Future<void> _configure() async {
    final peripheral = _peripheral!;
    state = BotLinkState.configuring;
    notifyListeners();

    try {
      // Brief pause so an auto-MTU / onServiceChanged from Android 14+
      // does not collide with our first discover.
      await Future<void>.delayed(_postMtuSettle);

      var services = await _central.discoverGATT(peripheral);
      var service = _botService(services);
      if (service == null) {
        Log.w(_tag, 'bot service missing after discover, retrying');
        await Future<void>.delayed(_postMtuSettle);
        services = await _central.discoverGATT(peripheral);
        service = _botService(services);
      }
      if (service == null) {
        throw StateError('bot service missing after connect');
      }
      GATTCharacteristic find(String uuid) => service!.characteristics
          .firstWhere((c) => c.uuid == UUID.fromString(uuid),
              orElse: () =>
                  throw StateError('characteristic $uuid missing'));
      _audioFromBotChar = find(BotUuids.audioFromBot);
      _audioToBotChar = find(BotUuids.audioToBot);
      _controlChar = find(BotUuids.control);
      _telemetryChar = find(BotUuids.telemetry);

      Log.i(_tag, 'GATT discovered, waiting for link to settle');
      await Future<void>.delayed(_postDiscoverSettle);

      await _enableNotify(peripheral, _audioFromBotChar!, 'audio');
      await _enableNotify(peripheral, _telemetryChar!, 'telemetry');

      try {
        mtu = await _central.requestMTU(peripheral, mtu: kPreferredMtu);
        Log.i(_tag, 'negotiated MTU $mtu');
      } catch (e) {
        // Not fatal: the chunker adapts frame size to `mtu`.
        Log.w(_tag, 'requestMTU failed, staying at $mtu: ${bleLogDetail(e)}');
      }

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
      lastError = bleFailureMessage('Setup', e);
      Log.e(_tag, 'configure failed (${bleLogDetail(e)})');
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
      _dropSession();
      _scheduleReconnect();
    }
  }

  /// Enable notifications. If the CCCD write ACK never arrives but the
  /// link still accepts GATT ops, continue — some OEM stacks complete ATT
  /// and then drop the Java callback the plugin waits on.
  Future<void> _enableNotify(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
    String name,
  ) async {
    Log.i(_tag, 'enabling $name notifications');
    try {
      await _central
          .setCharacteristicNotifyState(peripheral, characteristic, state: true)
          .timeout(_notifyTimeout);
    } on TimeoutException {
      Log.w(_tag, '$name notify ACK timed out, probing link');
      try {
        rssi = await _central
            .readRSSI(peripheral)
            .timeout(const Duration(seconds: 2));
        Log.w(_tag, '$name notify proceeding without ACK (rssi $rssi)');
      } on Object catch (e) {
        Log.e(_tag, '$name notify stuck (${bleLogDetail(e)})');
        throw TimeoutException('$name notify enable timed out');
      }
    }
  }

  void _scheduleReconnect() {
    if (_stopping || radioState != BluetoothLowEnergyState.poweredOn) return;
    // A failed connect completes the connect Future *and* emits a
    // disconnected event; both paths land here. Keep one timer.
    if (_reconnectTimer != null) return;

    _connectTimeout?.cancel();
    _connectTimeout = null;

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
      _reconnectTimer = null;
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
            Log.e(_tag, 'control write failed (${bleLogDetail(e)})');
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
            Log.w(_tag, 'audio write failed: ${bleLogDetail(e)}');
          }
        }
      }
    } finally {
      _pumping = false;
    }
  }

  // --- teardown ---

  GATTService? _botService(List<GATTService> services) {
    for (final s in services) {
      if (s.uuid == UUID.fromString(BotUuids.service)) return s;
    }
    return null;
  }

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
        Log.w(_tag, 'disconnect during teardown: ${bleLogDetail(e)}');
      }
    }
    _dropSession();
    await _audioController.close();
    await _telemetryController.close();
  }
}
