/// The foreground service isolate (M2).
///
/// This is where the bot actually lives. The service — not the UI — owns
/// the BLE link and the brain, so killing the Activity does not kill the
/// bot. The UI is a spectator: it sends [UiCommand]s and renders
/// [ServiceSnapshot]s.
///
/// Lifecycle stance (from the brief): kill → restart → re-warm is a normal
/// lifecycle, not an error. The transcript persists on every append; on
/// restart the session reloads it and re-warms, showing warming state on
/// the bot's LEDs while it does. START_STICKY, autoRunOnBoot and
/// allowAutoRestart handle the restart triggers; this file handles being
/// restartable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../../shared/audio_transport.dart';
import '../../shared/ble_protocol.dart';
import '../../shared/log.dart';
import '../bot_link.dart';
import '../brain/bot_brain.dart';
import '../brain/brain_session.dart';
import '../brain/fake_brain.dart';
import '../brain/gemma_brain.dart';
import '../brain/hybrid_brain.dart';
import '../brain/sherpa_clip_asr.dart';
import '../brain/transcript.dart';
import '../expressions.dart';
import 'bot_body.dart';
import 'notification_text.dart';
import 'service_ipc.dart';
import 'task_storage.dart';
import 'timer_store.dart';

const String _tag = 'BotService';

/// Entry point executed in the service's own Flutter engine. Must stay a
/// top-level function with this pragma or AOT builds cannot find it.
@pragma('vm:entry-point')
void botServiceStartCallback() {
  FlutterForegroundTask.setTaskHandler(BotTaskHandler());
}

final class BotTaskHandler extends TaskHandler {
  BotLink? _link;
  BrainSession? _session;
  TranscriptStore? _transcript;
  GemmaBrain? _gemma;
  HybridBrain? _hybrid;
  BotBody? _body;
  TimerStore? _timerStore;
  final Map<String, Timer> _dartTimers = {};
  Completer<({int percent, int millivolts, bool charging})>? _batteryWaiter;
  late UtteranceReassembler _reassembler;
  bool _bringUp = false;
  final List<StreamSubscription> _subscriptions = [];
  final SequenceCounter _controlSeq = SequenceCounter();
  final DateTime _startedAt = DateTime.now();

  // Audio diagnostics (same numbers the M1 debug panel showed).
  bool _liveMonitor = true;
  bool _playbackReady = false;
  bool _receivingUtterance = false;
  DateTime? _utteranceFirstArrival;
  DateTime? _utteranceLastArrival;
  Timer? _utteranceIdle;
  DateTime? _lastInboundAt;
  DateTime? _notifyProbeSentAt;
  DateTime? _notifyReadyAt;
  bool _notifyLinkReady = false;
  Int16List? _lastUtterancePcm;
  ReceiveStatsSnapshot? _lastReceive;
  EchoStatsSnapshot? _lastEcho;
  bool _echoing = false;

  // Bot status from telemetry.
  BotState _botState = BotState.idle;
  int? _batteryPercent;
  int? _batteryMillivolts;
  bool _batteryCharging = false;

  // Phone alerts (events injected by the native notification listener).
  // Default ON: the events only flow once the user grants Notification
  // access, so granting IS the opt-in; the toggle exists to turn the bot
  // reaction off while keeping the keep-alive benefit of the listener.
  static const String _phoneAlertsKey = 'phoneAlertsEnabled';
  bool _phoneAlertsEnabled = true;

  /// Actuation debounce on top of the listener's 3 s forward debounce: a
  /// burst of alerts becomes one blink+chirp, not a BLE flood.
  static const Duration _minPhoneAlertGap = Duration(seconds: 5);
  DateTime _lastPhoneAlertAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _phoneAlertRestore;

  final List<String> _activity = [];
  static const int _maxActivity = 40;

  // Snapshot throttle: state can churn per token during a response; the
  // UI needs ~5 Hz, not 25.
  static const Duration _minSnapshotGap = Duration(milliseconds: 200);
  DateTime _lastSnapshotAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingSnapshot;

  BrainSessionState? _lastExpressedBrainState;

  // Expression decay: a turn's mood lingers briefly after the brain goes
  // back to ready, then relaxes to the neutral resting face; if nothing
  // else happens the bot eventually dozes off. Keeps the face lively
  // instead of frozen on the last express() forever.
  static const Duration _expressionHold = Duration(seconds: 8);
  static const Duration _dozeAfterIdle = Duration(seconds: 60);
  Timer? _expressionDecay;

  BrainSessionState? _lastCaptionBrainState;
  DateTime _lastCaptionAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingCaption;
  static const Duration _minCaptionGap = Duration(milliseconds: 200);

  // Notification throttle: change-only, capped at one update per gap with a
  // trailing update so the final state always lands (same pattern as
  // _pushSnapshot). State churns per token during a response; the shade
  // does not need that.
  static const Duration _minNotificationGap = Duration(seconds: 2);
  String _lastNotificationText = '';
  DateTime _lastNotificationAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingNotification;

  // --- lifecycle ---

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (_bringUp) {
      Log.w(_tag, 'onStart re-entered; keeping existing session');
      return;
    }
    _bringUp = true;
    try {
      await _bringUpService(starter);
    } catch (e, stack) {
      _bringUp = false;
      Log.e(_tag, 'onStart failed', e, stack);
      rethrow;
    }
  }

  Future<void> _bringUpService(TaskStarter starter) async {
    Log.i(_tag, 'service starting (starter: ${starter.name})');
    _logActivity('Service started (${starter.name})');

    _transcript = TranscriptStore(const TaskKeyValueStore());
    _timerStore = TimerStore(const TaskKeyValueStore());
    await _timerStore!.load();
    _body = BotBody(
      timers: _timerStore!,
      sendControl: _sendControl,
      nextSequence: () => _controlSeq.next(),
      waitForBattery: _waitForBattery,
    );

    // CUTEBOT_FAKE_BRAIN=true keeps M2's canned brain for one-phone tests
    // that must not download 2.6 GB. Default is Gemma 4 E2B. HybridBrain
    // sits in front either way: ASR + formulaic intents skip the model.
    const useFake = bool.fromEnvironment('CUTEBOT_FAKE_BRAIN');
    final BotBrain inner;
    if (useFake) {
      Log.i(_tag, 'brain: FakeBrain + NLP (CUTEBOT_FAKE_BRAIN)');
      inner = FakeBrain();
    } else {
      _gemma = GemmaBrain(
        onChanged: () => _pushSnapshot(),
        executeTool: _executeTool,
      );
      inner = _gemma!;
      Log.i(_tag, 'brain: Gemma 4 E2B + NLP');
    }
    _hybrid = HybridBrain(
      inner: inner,
      // FakeBrain still dispatches from BrainSession.onToolCall.
      executeTool: useFake ? null : _executeTool,
      asr: SherpaClipAsr(),
      onHeard: (text) => _logActivity('Heard: $text'),
    );
    _session = BrainSession(
      brain: _hybrid!,
      transcript: _transcript!,
      onToolCall: (call) {
        _logActivity('Tool call: $call');
        // FakeBrain has no executor inside respond(); GemmaBrain already
        // awaited _executeTool before yielding the ToolCall.
        if (useFake) {
          unawaited(_executeTool(
              call.name, Map<String, dynamic>.from(call.arguments)));
        }
      },
    )..addListener(_onBrainChanged);

    _reassembler = UtteranceReassembler(
      onPcm: _onLivePcm,
      onUtterance: _onUtteranceComplete,
    );

    _link = BotLink(canRequestPermissions: false)..addListener(_onLinkChanged);
    _subscriptions.add(_link!.audioFromBot.listen(_onAudioFrame));
    _subscriptions.add(_link!.telemetry.listen(_onTelemetry));

    try {
      _phoneAlertsEnabled =
          await FlutterForegroundTask.getData<bool>(key: _phoneAlertsKey) ??
              true;
    } catch (e) {
      Log.w(_tag, 'phone alerts flag read failed: $e');
    }

    try {
      await FlutterPcmSound.setup(
        sampleRate: AudioWireFormat.sampleRate,
        channelCount: AudioWireFormat.channels,
      );
      await FlutterPcmSound.setFeedThreshold(0);
      _playbackReady = true;
    } catch (e) {
      // No speaker is a diagnostic loss, not a service failure.
      Log.e(_tag, 'PCM playback setup failed in service isolate', e);
      _logActivity('Speaker unavailable: $e');
    }

    await _link!.start();
    // Mute: no TTS. BLE audio-out stays for a later play_song tool.
    // Warm-up runs while the link connects; restore timers after the brain
    // is ready so a due timer enters the conversation queue, not a drop.
    unawaited(() async {
      await _session!.start();
      _restoreTimers();
    }());
    _pushSnapshot(force: true);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Heartbeat: even with no state churn the UI gets a fresh snapshot,
    // and a human tailing logcat sees the service is alive. Also cycle a
    // scan that came up after process resurrection but never hears the bot.
    _link?.onHeartbeat();
    _checkNotifyLiveness();
    _pushSnapshot(force: true);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    Log.w(_tag, 'service destroyed (timeout: $isTimeout)');
    _pendingSnapshot?.cancel();
    _pendingNotification?.cancel();
    _pendingCaption?.cancel();
    _phoneAlertRestore?.cancel();
    _expressionDecay?.cancel();
    _utteranceIdle?.cancel();
    for (final t in _dartTimers.values) {
      t.cancel();
    }
    _dartTimers.clear();
    _batteryWaiter = null;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _reassembler.reset();
    _session?.dispose();
    _session = null;
    _hybrid = null;
    _gemma = null;
    _body = null;
    _timerStore = null;
    _link?.dispose();
    _link = null;
    _bringUp = false;
    if (_playbackReady) {
      unawaited(FlutterPcmSound.release());
    }
    // Nothing to flush: the transcript persisted on every append.
  }

  // --- UI commands ---

  @override
  void onReceiveData(Object data) {
    final command = UiCommand.fromMap(data);
    if (command == null) {
      Log.w(_tag, 'unrecognized UI command: $data');
      return;
    }
    switch (command) {
      case SetLedUiCommand(:final red, :final green, :final blue, :final pattern):
        _sendControl(
            SetLedCommand(
              sequence: _controlSeq.next(),
              red: red,
              green: green,
              blue: blue,
              pattern: pattern,
            ),
            'set_led($red,$green,$blue,${pattern.name})');
      case WiggleUiCommand():
        _sendControl(WiggleCommand(sequence: _controlSeq.next()), 'wiggle');
      case PlaySoundUiCommand(:final sound):
        _sendControl(
            PlaySoundCommand(sequence: _controlSeq.next(), sound: sound),
            'play_sound(${sound.name})');
      case GetBatteryUiCommand():
        _sendControl(
            GetBatteryCommand(sequence: _controlSeq.next()), 'get_battery');
      case SetLiveMonitorUiCommand(:final enabled):
        _liveMonitor = enabled;
        _logActivity('Live monitor ${enabled ? 'on' : 'off'}');
      case EchoLastUtteranceUiCommand():
        unawaited(_echoLastUtterance());
      case SimulateUtteranceUiCommand(:final millis):
        _logActivity('Simulated utterance ($millis ms)');
        final clip = AudioClip(
            pcm: Int16List(millis * AudioWireFormat.sampleRate ~/ 1000));
        unawaited(_session?.handleUtterance(clip));
      case ClearTranscriptUiCommand():
        _logActivity('Transcript cleared');
        unawaited(_session?.clearTranscript());
      case SetPhoneAlertsUiCommand(:final enabled):
        _phoneAlertsEnabled = enabled;
        _logActivity('Phone alerts ${enabled ? 'on' : 'off'}');
        unawaited(FlutterForegroundTask.saveData(
            key: _phoneAlertsKey, value: enabled));
      case PhoneAlertUiCommand(:final packageName, :final category):
        _onPhoneAlert(packageName, category);
      case RequestSnapshotUiCommand():
        break; // snapshot goes out below either way
      case RetryBrainUiCommand():
        _logActivity('Retrying brain warm-up');
        unawaited(_session?.start());
    }
    _pushSnapshot(force: true);
  }

  // --- inbound audio: radio -> reassembler -> brain ---

  /// End-of-utterance is one BLE notify. With the 20–30% loss we see on
  /// this link, that frame often never arrives. The reassembler would then
  /// sit open until the *next* talk. Finalize after this much silence.
  static const Duration _utteranceIdleTimeout = Duration(milliseconds: 1500);

  void _onAudioFrame(AudioChunkMessage message) {
    final now = DateTime.now();
    _markInbound(now);
    final started = message.isUtteranceStart || !_receivingUtterance;
    if (started) {
      _utteranceFirstArrival = now;
      Log.i(_tag, 'utterance started (seq ${message.sequence})');
      _session?.noteIncomingAudio();
    }
    _utteranceLastArrival = now;
    _reassembler.add(message);
    // add() may have finalized a previous clip (lost-end + new start).
    _receivingUtterance = _reassembler.inUtterance;
    if (_receivingUtterance) {
      _utteranceIdle?.cancel();
      _utteranceIdle = Timer(_utteranceIdleTimeout, _onUtteranceIdle);
    }
    if (started || message.isUtteranceEnd) _pushSnapshot();
  }

  void _onUtteranceIdle() {
    _utteranceIdle = null;
    if (!_receivingUtterance) return;
    Log.w(_tag, 'utterance end missing, finalizing after idle');
    _reassembler.reset();
  }

  void _onLivePcm(Int16List pcm) {
    if (_liveMonitor && _playbackReady) {
      unawaited(FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm)));
    }
  }

  void _onUtteranceComplete(UtteranceResult result) {
    _utteranceIdle?.cancel();
    _utteranceIdle = null;
    _receivingUtterance = false;
    final wallMillis = (_utteranceFirstArrival != null &&
            _utteranceLastArrival != null)
        ? _utteranceLastArrival!.difference(_utteranceFirstArrival!).inMilliseconds
        : 0;
    final audioMillis = result.audioDuration.inMilliseconds;
    _lastReceive = ReceiveStatsSnapshot(
      frames: result.framesReceived,
      framesLost: result.framesLost,
      audioMillis: audioMillis,
      wallMillis: wallMillis,
      realTimeRate: wallMillis <= 0 ? 0 : audioMillis / wallMillis,
      checksumHex: result.checksumHex,
    );
    if (result.pcm.isNotEmpty) _lastUtterancePcm = result.pcm;
    _logActivity('Utterance: ${result.framesReceived} frames, '
        '${result.framesLost} lost, $audioMillis ms · crc ${result.checksumHex}');
    Log.i(_tag,
        'utterance: ${result.framesReceived} rx / ${result.framesLost} lost, crc ${result.checksumHex}');

    if (result.pcm.isNotEmpty) {
      unawaited(_session?.handleUtterance(AudioClip(pcm: result.pcm)));
    } else {
      _session?.cancelListening();
    }
    _pushSnapshot();
  }

  // --- telemetry ---

  void _onTelemetry(BotMessage message) {
    _markInbound(DateTime.now());
    switch (message) {
      case BatteryStatusMessage(:final percent, :final millivolts, :final charging):
        _batteryPercent = percent;
        _batteryMillivolts = millivolts;
        _batteryCharging = charging;
        final waiter = _batteryWaiter;
        _batteryWaiter = null;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete((
            percent: percent,
            millivolts: millivolts,
            charging: charging,
          ));
        }
        _logActivity('Battery $percent% ($millivolts mV)');
      case BotStateMessage(:final state):
        _botState = state;
        _logActivity('Bot state: ${state.name}');
      default:
        Log.w(_tag, 'unexpected telemetry: $message');
    }
    _updateNotification(); // battery is part of the notification text
    _pushSnapshot();
  }

  // --- brain -> bot expression ---

  void _onBrainChanged() {
    final session = _session;
    if (session == null) return;

    if (session.state != _lastExpressedBrainState) {
      _lastExpressedBrainState = session.state;
      _expressBrainState(session.state, hadError: session.lastError != null);
      _scheduleExpressionDecay(session.state);
    }
    _pushCaption(session);
    _updateNotification();
    _pushSnapshot();
  }

  /// Caption for a display bot (simulator or desk-bot OLED). Firmware without
  /// a screen ACKs and ignores [ShowTextCommand]. Mute path: the caption is
  /// the compact tool line (`express(delighted)` / `thinking…`), not speech.
  void _pushCaption(BrainSession session) {
    if (session.state == BrainSessionState.thinking) {
      _sendCaption('thinking…', isFinal: false);
    }
    if (session.state == BrainSessionState.responding &&
        session.responseText.isNotEmpty) {
      _sendCaption(session.responseText, isFinal: false);
    }
    if (_lastCaptionBrainState == BrainSessionState.responding &&
        session.state == BrainSessionState.ready &&
        session.lastResponseText.isNotEmpty) {
      _pendingCaption?.cancel();
      _pendingCaption = null;
      _sendCaption(session.lastResponseText, isFinal: true, force: true);
    }
    _lastCaptionBrainState = session.state;
  }

  void _sendCaption(String text, {required bool isFinal, bool force = false}) {
    if (!isFinal && !force) {
      final now = DateTime.now();
      final elapsed = now.difference(_lastCaptionAt);
      if (elapsed < _minCaptionGap) {
        _pendingCaption ??= Timer(_minCaptionGap - elapsed, () {
          _pendingCaption = null;
          final session = _session;
          if (session != null &&
              session.state == BrainSessionState.responding &&
              session.responseText.isNotEmpty) {
            _sendCaption(session.responseText, isFinal: false, force: true);
          }
        });
        return;
      }
    }
    _pendingCaption?.cancel();
    _pendingCaption = null;
    _lastCaptionAt = DateTime.now();

    final link = _link;
    if (link == null || link.state != BotLinkState.ready) return;
    // header(4) + cmd(1) + flags(1) + ATT(3) → remaining bytes for UTF-8.
    final maxUtf8 = (link.mtu - 9).clamp(16, 500);
    final utf8Text = _utf8Truncated(text, maxUtf8);
    _sendControl(
      ShowTextCommand(
        sequence: _controlSeq.next(),
        utf8Text: utf8Text,
        isFinal: isFinal,
      ),
      isFinal ? 'caption' : 'caption…',
      quiet: !isFinal,
      reconnectOnWriteFailure: false,
    );
  }

  static Uint8List _utf8Truncated(String text, int maxBytes) {
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) return Uint8List.fromList(bytes);
    var end = maxBytes;
    while (end > 0 && (bytes[end - 1] & 0xC0) == 0x80) {
      end--;
    }
    if (end > 0 && (bytes[end - 1] & 0x80) != 0) {
      end--;
    }
    return Uint8List.fromList(bytes.sublist(0, end));
  }

  /// Shows warming / thinking on the bot's body via the expression catalog.
  /// Ready and responding do not overwrite — model `express()` is the face.
  void _expressBrainState(BrainSessionState state, {required bool hadError}) {
    final mood = systemMoodForBrainState(state);
    if (mood != null) {
      _body?.showMood(mood, labelPrefix: 'system', quiet: true);
      return;
    }
    if (state == BrainSessionState.thinking) {
      // Not a catalog mood (BotMood is the express() tool schema). Purple
      // breathe is the reserved lifecycle signature the visor renders as
      // its dedicated "thinking" animation.
      _sendControl(
          SetLedCommand(
            sequence: _controlSeq.next(),
            red: 160,
            green: 0,
            blue: 255,
            pattern: LedPattern.breathe,
          ),
          'led thinking',
          quiet: true);
      return;
    }
    if (state == BrainSessionState.responding ||
        state == BrainSessionState.ready) {
      return;
    }
    final led = switch (state) {
      BrainSessionState.cold =>
        hadError ? (255, 0, 0, LedPattern.blink) : (0, 0, 0, LedPattern.off),
      _ => null,
    };
    if (led == null) return;
    _sendControl(
        SetLedCommand(
          sequence: _controlSeq.next(),
          red: led.$1,
          green: led.$2,
          blue: led.$3,
          pattern: led.$4,
        ),
        'led ${state.name}',
        quiet: true);
  }

  /// Once the brain settles on ready, let the turn's expression linger for
  /// [_expressionHold], then relax to neutral (LED off → resting face);
  /// after [_dozeAfterIdle] more of silence, doze off to sleepy. Any state
  /// change (new utterance, cue, warming) cancels the decay so a fresh
  /// expression is never cut short.
  void _scheduleExpressionDecay(BrainSessionState state) {
    _expressionDecay?.cancel();
    _expressionDecay = null;
    if (state != BrainSessionState.ready) return;
    _expressionDecay = Timer(_expressionHold, () {
      if (_session?.state != BrainSessionState.ready) return;
      _sendControl(
          SetLedCommand(
            sequence: _controlSeq.next(),
            red: 0,
            green: 0,
            blue: 0,
            pattern: LedPattern.off,
          ),
          'led idle',
          quiet: true);
      _expressionDecay = Timer(_dozeAfterIdle, () {
        if (_session?.state != BrainSessionState.ready) return;
        // Raw LED (no showMood): dozing off should not purr out loud.
        _sendControl(
            SetLedCommand(
              sequence: _controlSeq.next(),
              red: 0,
              green: 60,
              blue: 255,
              pattern: LedPattern.breathe,
            ),
            'led doze',
            quiet: true);
      });
    });
  }

  /// Tool calls from the brain, mapped onto BLE / timers / battery.
  Future<Map<String, dynamic>> _executeTool(
      String name, Map<String, dynamic> args) async {
    final body = _body;
    if (body == null) {
      return {'error': 'bot body not ready'};
    }
    try {
      final invoked = await body.invoke(name, args);
      if (invoked.armed != null) _armTimer(invoked.armed!);
      return invoked.result;
    } catch (e, stack) {
      Log.e(_tag, 'tool $name failed', e, stack);
      return {'error': '$e'};
    }
  }

  void _restoreTimers() {
    final store = _timerStore;
    if (store == null) return;
    for (final timer in store.pending) {
      _armTimer(timer);
    }
    if (store.pending.isNotEmpty) {
      Log.i(_tag, 'restored ${store.pending.length} timer(s)');
    }
  }

  void _armTimer(PendingTimer timer) {
    _dartTimers[timer.id]?.cancel();
    final delay = timer.remainingAt(DateTime.now());
    if (delay == Duration.zero) {
      unawaited(_fireTimer(timer));
      return;
    }
    _dartTimers[timer.id] = Timer(delay, () => unawaited(_fireTimer(timer)));
  }

  Future<void> _fireTimer(PendingTimer timer) async {
    _dartTimers.remove(timer.id)?.cancel();
    await _timerStore?.remove(timer.id);
    _logActivity('Timer fired: ${timer.label}');
    Log.i(_tag, 'timer ${timer.id} fired (${timer.label})');
    await _session?.handleCue(
      "A timer just finished: '${timer.label}'. "
      'Call express(alarm). Do not speak.',
    );
  }

  static const Duration _batteryWait = Duration(seconds: 2);

  Future<({int percent, int millivolts, bool charging})?> _waitForBattery() async {
    final waiter =
        Completer<({int percent, int millivolts, bool charging})>();
    _batteryWaiter = waiter;
    try {
      return await waiter.future.timeout(_batteryWait);
    } on TimeoutException {
      if (_batteryPercent != null) {
        return (
          percent: _batteryPercent!,
          millivolts: _batteryMillivolts ?? 0,
          charging: _batteryCharging,
        );
      }
      return null;
    } finally {
      if (identical(_batteryWaiter, waiter)) _batteryWaiter = null;
    }
  }

  // --- phone alerts (notification listener -> bot) ---

  /// Shows a phone notification on the bot's body: brief cyan blink +
  /// chirp, then back to whatever the brain state was expressing. The
  /// listener already did the keep-alive part (ensureRunning) natively, so
  /// a disconnected bot means there is simply nothing to do here.
  void _onPhoneAlert(String packageName, String category) {
    if (!_phoneAlertsEnabled) return;
    if (_link?.state != BotLinkState.ready) return;
    final now = DateTime.now();
    if (now.difference(_lastPhoneAlertAt) < _minPhoneAlertGap) return;
    _lastPhoneAlertAt = now;

    final label = category.isEmpty ? packageName : '$packageName ($category)';
    _logActivity('Phone alert: $label');
    _sendControl(
        SetLedCommand(
          sequence: _controlSeq.next(),
          red: 0,
          green: 180,
          blue: 255,
          pattern: LedPattern.blink,
        ),
        'alert led',
        quiet: true);
    _sendControl(
        PlaySoundCommand(sequence: _controlSeq.next(), sound: BotSound.chirp),
        'alert chirp',
        quiet: true);

    _phoneAlertRestore?.cancel();
    _phoneAlertRestore = Timer(const Duration(seconds: 2), () {
      final session = _session;
      if (session == null) return;
      _expressBrainState(session.state, hadError: session.lastError != null);
      // On ready the call above leaves the alert LED as-is; restart the
      // decay so the alert face still relaxes back to neutral.
      _scheduleExpressionDecay(session.state);
    });
  }

  // --- link ---

  void _onLinkChanged() {
    final link = _link;
    if (link == null) return;
    if (link.state == BotLinkState.ready) {
      if (!_notifyLinkReady) {
        _notifyLinkReady = true;
        _lastInboundAt = null;
        _notifyProbeSentAt = null;
        _notifyReadyAt = DateTime.now();
      }
      // (Re)connected: the bot may have missed state changes — re-express.
      final session = _session;
      if (session != null) {
        _expressBrainState(session.state,
            hadError: session.lastError != null);
      }
    } else {
      _notifyLinkReady = false;
      _notifyProbeSentAt = null;
      _notifyReadyAt = null;
    }
    _updateNotification();
    _pushSnapshot();
  }

  void _markInbound(DateTime at) {
    _lastInboundAt = at;
    _notifyProbeSentAt = null;
  }

  /// Writes still work with a stale CCCD (LED, notification chirps). A
  /// get_battery that is never answered with telemetry means notifies are
  /// dead — drop the GATT client and reconnect so CCCD is rewritten.
  /// Also used after inbound has gone quiet (GATT binder death, BT toggle
  /// without a disconnect callback): lastInboundAt is stale, not null.
  void _checkNotifyLiveness() {
    final link = _link;
    if (link == null) return;
    final now = DateTime.now();
    final action = notifyLivenessAction(
      state: link.state,
      now: now,
      lastInboundAt: _lastInboundAt,
      probeSentAt: _notifyProbeSentAt,
      readySince: _notifyReadyAt,
    );
    switch (action) {
      case NotifyLivenessAction.none:
        break;
      case NotifyLivenessAction.probe:
        Log.i(_tag, 'notify liveness probe (get_battery)');
        _notifyProbeSentAt = now;
        _sendControl(
          GetBatteryCommand(sequence: _controlSeq.next()),
          'notify probe',
          quiet: true,
        );
      case NotifyLivenessAction.reconnect:
        Log.w(_tag, 'no telemetry after notify probe; forcing reconnect');
        _notifyProbeSentAt = null;
        _lastInboundAt = null;
        unawaited(link.forceReconnect(reason: 'notify liveness'));
    }
  }

  void _sendControl(ControlMessage message, String label,
      {bool quiet = false, bool reconnectOnWriteFailure = true}) {
    final link = _link;
    if (link == null || link.state != BotLinkState.ready) {
      if (!quiet) _logActivity('$label skipped: not connected');
      return;
    }
    unawaited(link
        .sendControl(message, reconnectOnWriteFailure: reconnectOnWriteFailure)
        .then((_) {
      if (!quiet) _logActivity(label);
    }).catchError((Object e) {
      _logActivity('$label FAILED: $e');
      Log.e(_tag, '$label failed', e);
    }));
  }

  // --- echo diagnostic (M1 gate numbers, now through the service path) ---

  Future<void> _echoLastUtterance() async {
    final pcm = _lastUtterancePcm;
    final link = _link;
    if (pcm == null || link == null || _echoing) return;
    if (link.state != BotLinkState.ready) {
      _logActivity('Echo skipped: not connected');
      return;
    }
    _echoing = true;
    final chunker = UtteranceChunker(mtu: link.mtu);
    final audioMillis = pcm.length * 1000 ~/ AudioWireFormat.sampleRate;
    _logActivity('Echoing $audioMillis ms to bot (MTU ${link.mtu})');

    final started = DateTime.now();
    for (final frame in chunker.addSamples(pcm)) {
      link.sendAudioFrame(frame);
    }
    for (final frame in chunker.finish()) {
      link.sendAudioFrame(frame);
    }
    while (link.queuedAudioFrames > 0 && link.state == BotLinkState.ready) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final wallMillis = DateTime.now().difference(started).inMilliseconds;
    _lastEcho =
        EchoStatsSnapshot(audioMillis: audioMillis, wallMillis: wallMillis);
    _echoing = false;
    _logActivity('Echo: $audioMillis ms in $wallMillis ms '
        '(${_lastEcho!.realTimeRate.toStringAsFixed(2)}x RT)');
    _pushSnapshot();
  }

  // --- state out: snapshots + notification ---

  void _pushSnapshot({bool force = false}) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastSnapshotAt);
    if (!force && elapsed < _minSnapshotGap) {
      // Trailing push so the last change always lands.
      _pendingSnapshot ??= Timer(_minSnapshotGap - elapsed, () {
        _pendingSnapshot = null;
        _pushSnapshot(force: true);
      });
      return;
    }
    _pendingSnapshot?.cancel();
    _pendingSnapshot = null;
    _lastSnapshotAt = now;

    final link = _link;
    final session = _session;
    final transcript = session?.transcript ?? const <TranscriptEntry>[];
    final snapshot = ServiceSnapshot(
      sentAt: now,
      serviceStartedAt: _startedAt,
      linkState: link?.state ?? BotLinkState.idle,
      radioState: link?.radioState.name ?? 'unknown',
      mtu: link?.mtu ?? 23,
      botId: link?.botId,
      rssi: link?.rssi,
      reconnectAttempt: link?.reconnectAttempt ?? 0,
      linkError: link?.lastError,
      brainState: session?.state ?? BrainSessionState.cold,
      brainError: session?.lastError,
      brainKind: _gemma?.kind ?? 'FakeBrain',
      downloadPercent: _gemma?.downloadPercent,
      downloadRemainingSec: _gemma?.downloadRemainingSec,
      lastLatency: _hybrid?.lastLatency ?? _gemma?.lastLatency,
      replayedEntries: session?.replayedEntries ?? 0,
      droppedUtterances: session?.droppedUtterances ?? 0,
      responseText: session?.responseText ?? '',
      lastResponseText: session?.lastResponseText ?? '',
      botState: _botState,
      batteryPercent: _batteryPercent,
      batteryMillivolts: _batteryMillivolts,
      liveMonitor: _liveMonitor,
      phoneAlertsEnabled: _phoneAlertsEnabled,
      receivingUtterance: _receivingUtterance,
      lastReceive: _lastReceive,
      lastEcho: _lastEcho,
      transcript: transcript.length > 50
          ? transcript.sublist(transcript.length - 50)
          : transcript,
      activity: List.of(_activity),
    );
    FlutterForegroundTask.sendDataToMain(snapshot.toMap());
  }

  void _updateNotification() {
    final text = formatServiceNotificationText(
      linkState: _link?.state ?? BotLinkState.idle,
      brainState: _session?.state ?? BrainSessionState.cold,
      batteryPercent: _batteryPercent,
    );
    if (text == _lastNotificationText) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastNotificationAt);
    if (elapsed < _minNotificationGap) {
      // Trailing update so the last change always lands.
      _pendingNotification ??= Timer(_minNotificationGap - elapsed, () {
        _pendingNotification = null;
        _updateNotification();
      });
      return;
    }
    _pendingNotification?.cancel();
    _pendingNotification = null;
    _lastNotificationAt = now;
    _lastNotificationText = text;
    unawaited(FlutterForegroundTask.updateService(
      notificationTitle: 'Cute Bot',
      notificationText: text,
    ));
  }

  void _logActivity(String message) {
    final now = DateTime.now();
    final stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _activity.insert(0, '$stamp $message');
    if (_activity.length > _maxActivity) {
      _activity.removeRange(_maxActivity, _activity.length);
    }
  }
}
