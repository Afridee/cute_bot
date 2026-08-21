// Companion-mode controller, M2 shape: a thin client over the foreground
// service. The service isolate owns the BLE link and the brain
// (bot_service.dart); this class owns only what genuinely belongs to the
// UI process:
//
// - permission flows (BLE, notifications, battery-optimization exemption)
//   — these need an Activity, which the service never has
// - starting/attaching-to/stopping the service
// - rendering the latest ServiceSnapshot pushed over the task channel
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
import 'oem_care.dart';
import 'service/bot_service.dart';
import 'service/service_ipc.dart';

const String _tag = 'CompanionUi';

/// Where the controller is in its bring-up sequence.
enum CompanionUiPhase {
  idle,
  requestingPermissions,

  /// BLE permission denied — the service would sit unauthorized forever,
  /// so we do not start it. Terminal until the user grants.
  permissionDenied,
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

  bool _started = false;
  bool _disposed = false;

  /// Persisted marker: the battery-exemption dialog was already offered
  /// once on this install. Ask once, don't nag (M2.5) — the manual
  /// "Allow background" button in the UI remains for later minds.
  static const String _batteryPromptedKey = 'batteryExemptionPrompted';

  /// Persisted marker: the OEM keep-alive guidance page was already shown
  /// once on this install. Same ask-once policy as the battery prompt; the
  /// "Keep-alive tips" button in the UI remains for later minds.
  static const String _oemGuidanceShownKey = 'oemGuidanceShown';

  Future<void> start() async {
    if (_started) return;
    _started = true;

    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _initService();

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

    // Attach path: service already running (started earlier, or auto-
    // restarted after kill/boot). Don't redo permissions, just listen.
    if (await FlutterForegroundTask.isRunningService) {
      Log.i(_tag, 'attaching to already-running service');
      phase = CompanionUiPhase.running;
      _send(const RequestSnapshotUiCommand());
      unawaited(_refreshBatteryOptimization());
      notifyListeners();
      return;
    }

    phase = CompanionUiPhase.requestingPermissions;
    notifyListeners();

    // Notification permission (Android 13+): without it the foreground
    // service still runs but its notification is invisible; ask once.
    try {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      if (status != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      Log.w(_tag, 'notification permission flow failed: $e');
    }

    // BLE permission MUST be granted here: the service isolate has no
    // Activity and cannot show the dialog (bluetooth_low_energy authorize()
    // is Activity-bound).
    final bleGranted = await _ensureBlePermission();
    if (!bleGranted) {
      phase = CompanionUiPhase.permissionDenied;
      phaseError = 'Bluetooth permission is required. Grant it in settings, '
          'then come back.';
      notifyListeners();
      return;
    }

    // Battery-optimization exemption: OEM battery managers are one of the
    // two documented killers of this service. Ask ONCE per install; a
    // refusal is remembered and never re-prompted (the "Allow background"
    // button stays available in the UI).
    await _refreshBatteryOptimization();
    if (!batteryOptimizationExempt && !await _batteryPromptAlreadyOffered()) {
      try {
        await FlutterForegroundTask.saveData(
            key: _batteryPromptedKey, value: true);
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        await _refreshBatteryOptimization();
      } catch (e) {
        Log.w(_tag, 'battery optimization request failed: $e');
      }
    }

    phase = CompanionUiPhase.startingService;
    notifyListeners();

    final result = await FlutterForegroundTask.startService(
      serviceId: 1007,
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'Cute Bot',
      notificationText: 'starting…',
      callback: botServiceStartCallback,
    );
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

  Future<bool> _ensureBlePermission() async {
    try {
      final central = CentralManager();
      var state = central.state;
      if (state == BluetoothLowEnergyState.unknown) {
        // Platform side may still be initializing; wait for the first real
        // state, bounded.
        state = await central.stateChanged
            .map((e) => e.state)
            .firstWhere((s) => s != BluetoothLowEnergyState.unknown)
            .timeout(const Duration(seconds: 3),
                onTimeout: () => central.state);
      }
      if (state == BluetoothLowEnergyState.unauthorized) {
        return await central.authorize();
      }
      return state != BluetoothLowEnergyState.unsupported;
    } catch (e) {
      Log.e(_tag, 'BLE permission check failed', e);
      return false;
    }
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
    try {
      await FlutterForegroundTask.saveData(
          key: _oemGuidanceShownKey, value: true);
    } catch (e) {
      Log.w(_tag, 'OEM guidance flag write failed: $e');
    }
  }

  Future<bool> _batteryPromptAlreadyOffered() async {
    try {
      return await FlutterForegroundTask.getData<bool>(
              key: _batteryPromptedKey) ??
          false;
    } catch (e) {
      Log.w(_tag, 'battery prompt flag read failed: $e');
      return false;
    }
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

  Future<void> requestBatteryExemption() async {
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (e) {
      Log.w(_tag, 'battery optimization request failed: $e');
    }
    await _refreshBatteryOptimization();
  }

  /// Re-reads the native diagnostics (notification access, sticky death
  /// marker). Called when the app resumes, so granting Notification access
  /// in system settings is reflected the moment the user comes back.
  Future<void> refreshOemDiagnostics() async {
    final refreshed = await OemCare.diagnostics();
    if (refreshed == null) return;
    oemDiagnostics = refreshed;
    notifyListeners();
  }

  /// Deep-link to the system Notification access screen. Manual button —
  /// available forever, unlike the ask-once auto-shown guidance.
  Future<void> openNotificationAccessSettings() =>
      OemCare.openNotificationAccessSettings();

  /// Deliberate user stop — the only path that kills the bot on purpose.
  Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
    phase = CompanionUiPhase.stopped;
    snapshot = null;
    notifyListeners();
  }

  Future<void> restartService() async {
    phase = CompanionUiPhase.idle;
    _started = false;
    snapshot = null;
    await start();
  }

  // --- commands through to the service ---

  void setLed(int red, int green, int blue, LedPattern pattern) => _send(
      SetLedUiCommand(red: red, green: green, blue: blue, pattern: pattern));

  void wiggle() => _send(const WiggleUiCommand());

  void playSound(BotSound sound) => _send(PlaySoundUiCommand(sound));

  void getBattery() => _send(const GetBatteryUiCommand());

  void toggleLiveMonitor() =>
      _send(SetLiveMonitorUiCommand(!(snapshot?.liveMonitor ?? true)));

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
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    companionLink.removeListener(notifyListeners);
    companionLink.dispose();
    super.dispose();
  }
}
