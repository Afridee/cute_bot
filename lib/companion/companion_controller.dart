// Companion-mode controller, M2 shape: a thin client over the foreground
// service. The service isolate owns the BLE link and the brain
// (bot_service.dart); this class owns only what genuinely belongs to the
// UI process:
//
// - permission flows (BLE, notifications, battery-optimization exemption)
//   — these need an Activity, which the service never has
// - starting/attaching-to/stopping the service
// - rendering the latest ServiceSnapshot pushed over the task channel
// - first-run setup facts (Docs/companion-setup.md)
//
// Deliberately NOT here anymore: BotLink, audio, the brain. Killing this
// object (or the whole Activity) must not kill the bot.

import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../shared/ble_protocol.dart';
import '../shared/log.dart';
import 'companion_device_link.dart';
import 'debug_flags.dart';
import 'oem_care.dart';
import 'service/bot_service.dart';
import 'service/fast_intent_store.dart';
import 'service/service_ipc.dart';
import 'setup/companion_setup.dart';

const String _tag = 'CompanionUi';

/// Where the controller is in its bring-up sequence.
enum CompanionUiPhase {
  idle,
  startingService,

  /// Service running (or attached to an already-running one); snapshots
  /// flow. The normal state.
  running,
  stopped,
}

final class CompanionController extends ChangeNotifier {
  CompanionUiPhase phase = CompanionUiPhase.idle;
  String? phaseError;

  /// Latest state pushed by the service. Null until the first snapshot.
  ServiceSnapshot? snapshot;

  /// Time of the last snapshot, to surface a stale service in the UI.
  DateTime? lastSnapshotAt;

  bool batteryOptimizationExempt = false;

  /// Filled once at [start]; null until then (or on channel failure).
  OemDiagnostics? oemDiagnostics;

  /// True exactly once per install: the service died behind our back on an
  /// aggressive OEM (vivo/iQOO cleaner force-stop) and the guidance page has
  /// not been shown yet. The page consumes it via [markOemGuidanceShown].
  bool oemGuidancePending = false;

  /// Whether this device's OEM is known to force-stop background apps —
  /// keeps the manual "Keep-alive tips" entry point visible in the UI.
  bool get isAggressiveOem => oemDiagnostics?.isAggressiveOem ?? false;

  /// Notification access = phone alerts on the bot + the OS re-binding our
  /// listener (reviving the service) after OEM cleaner kills.
  bool get notificationAccessGranted =>
      oemDiagnostics?.notificationAccessGranted ?? false;

  /// CDM association state (M2.5). Owned here because the CDM chooser needs
  /// an Activity, same as the permission flows.
  final CompanionDeviceLink companionLink = CompanionDeviceLink();

  /// Compile-time FakeBrain: setup omits the 2.6 GB wait.
  static const bool fakeBrain = bool.fromEnvironment('CUTEBOT_FAKE_BRAIN');

  bool setupFactsLoaded = false;
  bool welcomeSeen = false;
  bool notificationsGranted = false;
  bool notificationPermanentlyDenied = false;
  bool oemKeepAliveAcknowledged = false;
  bool oemKeepAliveSkipped = false;
  bool cdmSkipped = false;
  bool voiceEnrollSkipped = false;
  bool voiceEnrollHasOverlay = false;
  bool voiceEnrollForced = false;

  BluetoothLowEnergyState radioState = BluetoothLowEnergyState.unknown;

  bool get bleAuthorized =>
      radioState == BluetoothLowEnergyState.poweredOn ||
      radioState == BluetoothLowEnergyState.poweredOff;

  bool get bluetoothOn => radioState == BluetoothLowEnergyState.poweredOn;

  bool get brainReady =>
      snapshot != null && companionBrainIsReady(snapshot!.brainState);

  CompanionSetupFacts get setupFacts => CompanionSetupFacts(
        welcomeSeen: welcomeSeen,
        notificationsGranted: notificationsGranted,
        bleAuthorized: bleAuthorized,
        bluetoothOn: bluetoothOn,
        batteryUnrestricted: batteryOptimizationExempt,
        notificationAccessGranted: notificationAccessGranted,
        isAggressiveOem: isAggressiveOem,
        oemKeepAliveAcknowledged: oemKeepAliveAcknowledged,
        oemKeepAliveSkipped: oemKeepAliveSkipped,
        cdmAssociated: companionLink.state.associated,
        cdmSkipped: cdmSkipped,
        brainReady: brainReady,
        fakeBrain: fakeBrain,
        voiceEnrollSkipped: voiceEnrollSkipped,
        voiceEnrollHasOverlay: voiceEnrollHasOverlay ||
            (snapshot?.voiceEnrollHasOverlay ?? false),
      );

  CompanionSetupStep get setupStep {
    if (voiceEnrollForced) {
      final blocking = firstBlockingCompanionSetupStep(setupFacts);
      if (blocking == CompanionSetupStep.done ||
          blocking == CompanionSetupStep.voiceEnroll) {
        return CompanionSetupStep.voiceEnroll;
      }
      return blocking;
    }
    return resolveCompanionSetupStep(setupFacts);
  }

  bool get canStartService => notificationsGranted && bluetoothOn;

  bool _started = false;
  bool _disposed = false;
  bool _startingService = false;

  final CentralManager _central = CentralManager();
  StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>? _radioSub;

  /// Persisted marker: the OEM keep-alive guidance page was already shown
  /// once on this install. Same ask-once policy as the battery prompt; the
  /// "Keep-alive tips" button in the UI remains for later minds.
  static const String _oemGuidanceShownKey = 'oemGuidanceShown';

  static const String _welcomeSeenKey = 'setupWelcomeSeen';
  static const String _oemAckKey = 'oemKeepAliveAcknowledged';
  static const String _oemSkipKey = 'oemKeepAliveSkipped';
  static const String _cdmSkipKey = 'cdmSkipped';
  static const String _voiceEnrollSkipKey = 'voiceEnrollSkipped';

  Future<void> start() async {
    if (_started) return;
    _started = true;

    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _initService();
    _bindRadio();

    // CDM association state (M2.5): refresh also re-arms presence
    // observation natively. Fire-and-forget; the card renders when ready.
    companionLink.addListener(notifyListeners);
    unawaited(companionLink.refresh());

    // OEM-killer detection. Observed on the iQOO Neo 10: vivo's cleaner
    // force-stops the app, which kills the service AND blocks every restart
    // mechanism until the next manual launch — i.e. right now. The native
    // side keeps a sticky wanted-but-dead marker (so a watchdog revival
    // can't hide the death); if set on an aggressive OEM, teach the user
    // once via the guidance page.
    await _checkOemKiller();
    await _loadSetupFlags();
    await _refreshNotificationPermission();
    await _refreshBatteryOptimization();
    await _refreshRadio();

    setupFactsLoaded = true;
    notifyListeners();

    // Attach path: service already running (started earlier, or auto-
    // restarted after kill/boot). Don't redo permissions, just listen.
    if (await FlutterForegroundTask.isRunningService) {
      Log.i(_tag, 'attaching to already-running service');
      phase = CompanionUiPhase.running;
      _send(const RequestSnapshotUiCommand());
      notifyListeners();
      return;
    }

    // Returning user / mid-wizard: start as soon as notification + BLE
    // are already true so the model can download in parallel.
    if (canStartService) {
      await ensureServiceStarted();
    }
  }

  void _bindRadio() {
    _radioSub ??= _central.stateChanged.listen((event) {
      radioState = event.state;
      if (canStartService) unawaited(ensureServiceStarted());
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _refreshRadio() async {
    try {
      var state = _central.state;
      if (state == BluetoothLowEnergyState.unknown) {
        state = await _central.stateChanged
            .map((e) => e.state)
            .firstWhere((s) => s != BluetoothLowEnergyState.unknown)
            .timeout(const Duration(seconds: 3),
                onTimeout: () => _central.state);
      }
      radioState = state;
    } catch (e) {
      Log.w(_tag, 'radio state read failed: $e');
    }
  }

  Future<void> _loadSetupFlags() async {
    welcomeSeen = await _readFlag(_welcomeSeenKey);
    oemKeepAliveAcknowledged = await _readFlag(_oemAckKey);
    oemKeepAliveSkipped = await _readFlag(_oemSkipKey);
    cdmSkipped = await _readFlag(_cdmSkipKey);
    voiceEnrollSkipped = await _readFlag(_voiceEnrollSkipKey);
    voiceEnrollHasOverlay = await _overlayPresent();
  }

  Future<bool> _overlayPresent() async {
    try {
      final raw = await FlutterForegroundTask.getData<String>(
          key: FastIntentStore.storageKey);
      return raw != null && raw.isNotEmpty;
    } catch (e) {
      Log.w(_tag, 'overlay read failed: $e');
      return false;
    }
  }

  Future<bool> _readFlag(String key) async {
    try {
      return await FlutterForegroundTask.getData<bool>(key: key) ?? false;
    } catch (e) {
      Log.w(_tag, '$key read failed: $e');
      return false;
    }
  }

  Future<void> _writeFlag(String key, bool value) async {
    try {
      await FlutterForegroundTask.saveData(key: key, value: value);
    } catch (e) {
      Log.w(_tag, '$key write failed: $e');
    }
  }

  void _initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cute_bot_service',
        channelName: 'Cute Bot',
        channelDescription:
            'Keeps the bot connected and the brain warm in the background.',
        // LOW: never buzzes, never sounds, but stays visible in the shade
        // and status bar (MIN hides it entirely on several OEMs, which
        // makes the service state invisible — bad for a debuggable
        // companion). Channel importance is STICKY once the channel exists
        // on a device; this was the plugin default (LOW) since M2, so
        // existing installs already match. If this ever changes, bump the
        // channel id or have testers clear app data.
        // NOTE: BotServiceStarter.kt creates this same channel (same id,
        // IMPORTANCE_LOW) for the watchdog fallback notification — keep
        // them in sync.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ), // iOS unsupported by design (see README); required arg regardless.
      foregroundTaskOptions: ForegroundTaskOptions(
        // Heartbeat snapshot every 5 s; real updates are push-on-change.
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
    );
  }

  Future<void> _checkOemKiller() async {
    oemDiagnostics = await OemCare.diagnostics();
    final diag = oemDiagnostics;
    if (diag == null || !diag.isAggressiveOem || !diag.serviceDiedUnexpectedly) {
      return;
    }
    Log.w(_tag,
        'service died behind our back on ${diag.manufacturer}/${diag.brand}');
    try {
      final shown =
          await FlutterForegroundTask.getData<bool>(key: _oemGuidanceShownKey) ??
              false;
      if (!shown) oemGuidancePending = true;
    } catch (e) {
      Log.w(_tag, 'OEM guidance flag read failed: $e');
    }
  }

  /// Called by the UI the moment it pushes the guidance page: consumes the
  /// pending flag and persists ask-once, even if the user backs right out.
  Future<void> markOemGuidanceShown() async {
    oemGuidancePending = false;
    await _writeFlag(_oemGuidanceShownKey, true);
    if (!_disposed) notifyListeners();
  }

  Future<void> _refreshBatteryOptimization() async {
    try {
      batteryOptimizationExempt =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (e) {
      Log.w(_tag, 'battery optimization check failed: $e');
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _refreshNotificationPermission() async {
    try {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      notificationsGranted = status == NotificationPermission.granted;
      notificationPermanentlyDenied =
          status == NotificationPermission.permanently_denied;
    } catch (e) {
      Log.w(_tag, 'notification permission check failed: $e');
    }
  }

  Future<void> requestNotifications() async {
    try {
      final status = await FlutterForegroundTask.requestNotificationPermission();
      notificationsGranted = status == NotificationPermission.granted;
      notificationPermanentlyDenied =
          status == NotificationPermission.permanently_denied;
    } catch (e) {
      Log.w(_tag, 'notification permission request failed: $e');
    }
    if (canStartService) unawaited(ensureServiceStarted());
    if (!_disposed) notifyListeners();
  }

  Future<void> requestBle() async {
    try {
      await _refreshRadio();
      if (radioState == BluetoothLowEnergyState.unauthorized) {
        await _central.authorize();
        await _refreshRadio();
      }
    } catch (e) {
      Log.e(_tag, 'BLE permission request failed', e);
    }
    if (canStartService) unawaited(ensureServiceStarted());
    if (!_disposed) notifyListeners();
  }

  Future<void> openAppSettings() => OemCare.openAppSettings();

  Future<void> openBluetoothSettings() => OemCare.openBluetoothSettings();

  Future<void> requestBatteryExemption() async {
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (e) {
      Log.w(_tag, 'battery optimization request failed: $e');
    }
    await _refreshBatteryOptimization();
  }

  /// Re-reads native diagnostics, battery, notifications, and radio.
  /// Called when the app resumes so settings grants land without a restart.
  Future<void> refreshSetupFacts() async {
    final refreshed = await OemCare.diagnostics();
    if (refreshed != null) oemDiagnostics = refreshed;
    await _refreshNotificationPermission();
    await _refreshBatteryOptimization();
    await _refreshRadio();
    if (canStartService) unawaited(ensureServiceStarted());
    if (!_disposed) notifyListeners();
  }

  /// Deep-link to the system Notification access screen. Manual button —
  /// available forever, unlike the ask-once auto-shown guidance.
  Future<void> openNotificationAccessSettings() =>
      OemCare.openNotificationAccessSettings();

  Future<void> markWelcomeSeen() async {
    welcomeSeen = true;
    await _writeFlag(_welcomeSeenKey, true);
    if (!_disposed) notifyListeners();
  }

  Future<void> acknowledgeOemKeepAlive() async {
    oemKeepAliveAcknowledged = true;
    await _writeFlag(_oemAckKey, true);
    if (!_disposed) notifyListeners();
  }

  Future<void> skipOemKeepAlive() async {
    oemKeepAliveSkipped = true;
    await _writeFlag(_oemSkipKey, true);
    if (!_disposed) notifyListeners();
  }

  Future<void> skipCdm() async {
    cdmSkipped = true;
    await _writeFlag(_cdmSkipKey, true);
    if (!_disposed) notifyListeners();
  }

  Future<void> skipVoiceEnroll() async {
    voiceEnrollForced = false;
    setVoiceEnroll(false);
    voiceEnrollSkipped = true;
    await _writeFlag(_voiceEnrollSkipKey, true);
    if (!_disposed) notifyListeners();
  }

  void setVoiceEnroll(bool enabled) =>
      _send(SetVoiceEnrollUiCommand(enabled));

  void saveVoiceEnrollOverlay(String overlayJson) {
    _send(SaveVoiceEnrollUiCommand(overlayJson: overlayJson));
    voiceEnrollHasOverlay = true;
    voiceEnrollForced = false;
    if (!_disposed) notifyListeners();
  }

  void beginVoiceReenroll() {
    voiceEnrollForced = true;
    if (!_disposed) notifyListeners();
  }

  void retryBrain() => _send(const RetryBrainUiCommand());

  /// Start the service once notification + Bluetooth are granted. Safe to
  /// call repeatedly; no-ops if already running or still unauthorized.
  Future<void> ensureServiceStarted() async {
    if (_disposed || _startingService) return;
    if (!canStartService) return;
    if (phase == CompanionUiPhase.running) return;
    if (await FlutterForegroundTask.isRunningService) {
      phase = CompanionUiPhase.running;
      _send(const RequestSnapshotUiCommand());
      if (!_disposed) notifyListeners();
      return;
    }

    _startingService = true;
    phase = CompanionUiPhase.startingService;
    phaseError = null;
    notifyListeners();

    final result = await FlutterForegroundTask.startService(
      serviceId: 1007,
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'Cute Bot',
      notificationText: 'starting…',
      callback: botServiceStartCallback,
    );
    _startingService = false;
    if (_disposed) return;

    if (result is ServiceRequestFailure) {
      phase = CompanionUiPhase.stopped;
      phaseError = 'Service failed to start: ${result.error}';
      Log.e(_tag, 'startService failed', result.error);
    } else {
      phase = CompanionUiPhase.running;
      phaseError = null;
      _send(const RequestSnapshotUiCommand());
    }
    notifyListeners();
  }

  /// Deliberate user stop — the only path that kills the bot on purpose.
  Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
    phase = CompanionUiPhase.stopped;
    snapshot = null;
    notifyListeners();
  }

  Future<void> restartService() async {
    phase = CompanionUiPhase.idle;
    snapshot = null;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    await ensureServiceStarted();
  }

  // --- commands through to the service ---

  void setLed(int red, int green, int blue, LedPattern pattern) => _send(
      SetLedUiCommand(red: red, green: green, blue: blue, pattern: pattern));

  void wiggle() => _send(const WiggleUiCommand());

  void playSound(BotSound sound) => _send(PlaySoundUiCommand(sound));

  void getBattery() => _send(const GetBatteryUiCommand());

  void toggleLiveMonitor() => _send(
      SetLiveMonitorUiCommand(!(snapshot?.liveMonitor ?? kLiveMonitorDefault)));

  void setPhoneAlerts(bool enabled) =>
      _send(SetPhoneAlertsUiCommand(enabled));

  void echoLastUtterance() => _send(const EchoLastUtteranceUiCommand());

  void simulateUtterance() =>
      _send(const SimulateUtteranceUiCommand(millis: 1200));

  void clearTranscript() => _send(const ClearTranscriptUiCommand());

  void _send(UiCommand command) {
    try {
      FlutterForegroundTask.sendDataToTask(command.toMap());
    } catch (e) {
      Log.w(_tag, 'sendDataToTask failed: $e');
    }
  }

  // --- inbound snapshots ---

  void _onTaskData(Object data) {
    final decoded = ServiceSnapshot.fromMap(data);
    if (decoded == null) return;
    snapshot = decoded;
    lastSnapshotAt = DateTime.now();
    if (decoded.voiceEnrollHasOverlay) voiceEnrollHasOverlay = true;
    if (phase != CompanionUiPhase.running) {
      // Snapshots prove the service is up regardless of our bookkeeping.
      phase = CompanionUiPhase.running;
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // NOTE: the service keeps running — that is the whole point of M2.
    unawaited(_radioSub?.cancel());
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    companionLink.removeListener(notifyListeners);
    companionLink.dispose();
    super.dispose();
  }
}
