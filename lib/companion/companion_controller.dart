// Companion-mode controller (M1). Composes BotLink (radio) with the
// framing/reassembly layer and exposes everything the debug panel needs:
//
// - live monitor: bot mic audio plays on this phone as it arrives (this is
//   how a human judges transport latency directly)
// - per-utterance stats for the bandwidth gate: frames, loss, checksum,
//   receive rate vs real time, worst inter-frame gap
// - replay of the last utterance and echo back to the bot's speaker (the
//   phone -> bot half of the duplex test), with throughput measured
// - control commands (LED / wiggle / sound / battery) with round-trip time
//   measured via the acked control write + telemetry reply

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../shared/audio_transport.dart';
import '../shared/ble_protocol.dart';
import '../shared/log.dart';
import 'bot_link.dart';

const String _tag = 'Companion';

/// One line in the on-screen activity log.
final class CompanionLogEntry {
  CompanionLogEntry(this.message) : timestamp = DateTime.now();
  final DateTime timestamp;
  final String message;
}

/// Bandwidth-gate numbers for one received utterance.
final class ReceiveStats {
  const ReceiveStats({
    required this.result,
    required this.wallMillis,
    required this.maxInterFrameGapMillis,
  });

  final UtteranceResult result;

  /// Wall-clock time from first to last frame arrival.
  final int wallMillis;

  /// Worst gap between consecutive frame arrivals — a proxy for jitter
  /// a playback buffer would need to absorb.
  final int maxInterFrameGapMillis;

  int get audioMillis => result.audioDuration.inMilliseconds;

  /// Receive rate as a multiple of real time. >= 1.0 passes the gate.
  double get realTimeRate =>
      wallMillis <= 0 ? double.infinity : audioMillis / wallMillis;

  /// Payload throughput on the wire (ADPCM bits, not counting headers).
  double get kbps => wallMillis <= 0
      ? 0
      : (result.framesReceived * AudioWireFormat.adpcmBlockBytes * 8) /
          wallMillis;
}

/// Throughput numbers for one utterance echoed back to the bot.
final class EchoStats {
  const EchoStats({required this.audioMillis, required this.wallMillis});

  final int audioMillis;
  final int wallMillis;

  double get realTimeRate =>
      wallMillis <= 0 ? double.infinity : audioMillis / wallMillis;
}

final class CompanionController extends ChangeNotifier {
  CompanionController() {
    _reassembler = UtteranceReassembler(
      onPcm: _onLivePcm,
      onUtterance: _onUtteranceComplete,
    );
  }

  final BotLink link = BotLink();
  late final UtteranceReassembler _reassembler;

  final List<StreamSubscription> _subscriptions = [];

  // --- state surfaced to the UI ---

  /// Play bot audio on this phone's speaker as it arrives.
  bool liveMonitor = true;

  bool receivingUtterance = false;
  int framesThisUtterance = 0;

  ReceiveStats? lastReceive;
  Int16List? lastUtterancePcm;

  bool echoing = false;
  EchoStats? lastEcho;

  BotState botState = BotState.idle;
  BatteryStatusMessage? battery;
  int? batteryRttMillis;

  final List<CompanionLogEntry> activityLog = [];
  static const int _maxLogEntries = 60;

  // --- internals ---

  final SequenceCounter _controlSeq = SequenceCounter();

  DateTime? _utteranceFirstArrival;
  DateTime? _lastFrameArrival;
  int _maxInterFrameGapMillis = 0;

  DateTime? _batteryRequestedAt;

  bool _playbackReady = false;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    link.addListener(notifyListeners);
    _subscriptions.add(link.audioFromBot.listen(_onAudioFrame));
    _subscriptions.add(link.telemetry.listen(_onTelemetry));

    try {
      await FlutterPcmSound.setup(
        sampleRate: AudioWireFormat.sampleRate,
        channelCount: AudioWireFormat.channels,
      );
      await FlutterPcmSound.setFeedThreshold(0);
      _playbackReady = true;
    } catch (e) {
      // Playback failure must not take down the link.
      Log.e(_tag, 'PCM playback setup failed', e);
      _logActivity('Speaker unavailable: $e');
    }

    await link.start();
  }

  // --- inbound audio ---

  void _onAudioFrame(AudioChunkMessage message) {
    final now = DateTime.now();
    if (message.isUtteranceStart || !receivingUtterance) {
      receivingUtterance = true;
      framesThisUtterance = 0;
      _utteranceFirstArrival = now;
      _lastFrameArrival = now;
      _maxInterFrameGapMillis = 0;
    } else if (_lastFrameArrival != null) {
      final gap = now.difference(_lastFrameArrival!).inMilliseconds;
      if (gap > _maxInterFrameGapMillis) _maxInterFrameGapMillis = gap;
    }
    _lastFrameArrival = now;
    if (message.adpcmBlock.isNotEmpty) framesThisUtterance += 1;

    _reassembler.add(message);

    // Keep UI churn off the audio path: ~every half second.
    if (framesThisUtterance % 25 == 0 || message.isUtteranceEnd) {
      notifyListeners();
    }
  }

  void _onLivePcm(Int16List pcm) {
    if (liveMonitor && _playbackReady) {
      unawaited(FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm)));
    }
  }

  void _onUtteranceComplete(UtteranceResult result) {
    receivingUtterance = false;
    final first = _utteranceFirstArrival;
    final last = _lastFrameArrival;
    final wallMillis = (first != null && last != null)
        ? last.difference(first).inMilliseconds
        : 0;

    lastReceive = ReceiveStats(
      result: result,
      wallMillis: wallMillis,
      maxInterFrameGapMillis: _maxInterFrameGapMillis,
    );
    if (result.pcm.isNotEmpty) lastUtterancePcm = result.pcm;

    final s = lastReceive!;
    _logActivity(
        'Utterance: ${result.framesReceived} frames, ${result.framesLost} lost'
        '${result.duplicateFrames > 0 ? ', ${result.duplicateFrames} dup' : ''}'
        '${result.staleFrames > 0 ? ', ${result.staleFrames} stale' : ''}'
        ' · ${s.audioMillis} ms audio in ${s.wallMillis} ms'
        ' (${s.realTimeRate.toStringAsFixed(2)}x RT, '
        '${s.kbps.toStringAsFixed(0)} kbps)'
        ' · crc ${result.checksumHex}');
    if (!result.sawStart) _logActivity('  first frame was lost');
    if (!result.sawEnd) _logActivity('  end frame never arrived');
    Log.i(_tag,
        'utterance done: ${result.framesReceived} rx / ${result.framesLost} lost, ${s.realTimeRate.toStringAsFixed(2)}x RT, crc ${result.checksumHex}');
    notifyListeners();
  }

  // --- inbound telemetry ---

  void _onTelemetry(BotMessage message) {
    switch (message) {
      case BatteryStatusMessage():
        battery = message;
        final requestedAt = _batteryRequestedAt;
        if (requestedAt != null) {
          batteryRttMillis =
              DateTime.now().difference(requestedAt).inMilliseconds;
          _batteryRequestedAt = null;
          _logActivity(
              'Battery ${message.percent}% (${message.millivolts} mV) — RTT $batteryRttMillis ms');
        } else {
          _logActivity('Battery ${message.percent}%');
        }
      case BotStateMessage(:final state):
        botState = state;
        _logActivity('Bot state: ${state.name}');
      default:
        Log.w(_tag, 'unexpected telemetry: $message');
    }
    notifyListeners();
  }

  // --- local replay ---

  void playLastUtterance() {
    final pcm = lastUtterancePcm;
    if (pcm == null || !_playbackReady) return;
    _logActivity('Replaying last utterance locally');
    unawaited(FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm)));
  }

  // --- echo to bot (phone -> bot audio path, duplex half of the gate) ---

  Future<void> echoToBot() async {
    final pcm = lastUtterancePcm;
    if (pcm == null || echoing || link.state != BotLinkState.ready) return;
    echoing = true;
    notifyListeners();

    // Chunk at the *current* MTU — this is the fallback path the protocol
    // requires when the OS grants less than 517. Fresh chunker per echo:
    // MTU can change across reconnects. (Sequence restarts at 0, which the
    // receiver accepts because the start-of-utterance flag resets it.)
    final chunker = UtteranceChunker(mtu: link.mtu);
    final audioMillis = pcm.length * 1000 ~/ AudioWireFormat.sampleRate;
    _logActivity('Echoing $audioMillis ms to bot (MTU ${link.mtu}, '
        '${chunker.samplesPerFrame} samples/frame)');

    final started = DateTime.now();
    for (final frame in chunker.addSamples(pcm)) {
      link.sendAudioFrame(frame);
    }
    for (final frame in chunker.finish()) {
      link.sendAudioFrame(frame);
    }

    // Fire-and-forget writes: wait for the queue to drain to measure
    // actual wire throughput.
    while (link.queuedAudioFrames > 0 && link.state == BotLinkState.ready) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final wallMillis = DateTime.now().difference(started).inMilliseconds;

    lastEcho = EchoStats(audioMillis: audioMillis, wallMillis: wallMillis);
    echoing = false;
    _logActivity('Echo sent: $audioMillis ms audio in $wallMillis ms '
        '(${lastEcho!.realTimeRate.toStringAsFixed(2)}x RT)'
        '${link.audioFramesDroppedOnSend > 0 ? ' · ${link.audioFramesDroppedOnSend} dropped from queue' : ''}');
    Log.i(_tag,
        'echo done: $audioMillis ms in $wallMillis ms (${lastEcho!.realTimeRate.toStringAsFixed(2)}x RT)');
    notifyListeners();
  }

  // --- control commands ---

  Future<void> setLed(int red, int green, int blue, LedPattern pattern) =>
      _control(
          SetLedCommand(
            sequence: _controlSeq.next(),
            red: red,
            green: green,
            blue: blue,
            pattern: pattern,
          ),
          'set_led rgb($red,$green,$blue) ${pattern.name}');

  Future<void> wiggle() =>
      _control(WiggleCommand(sequence: _controlSeq.next()), 'wiggle');

  Future<void> playSound(BotSound sound) => _control(
      PlaySoundCommand(sequence: _controlSeq.next(), sound: sound),
      'play_sound ${sound.name}');

  Future<void> getBattery() {
    _batteryRequestedAt = DateTime.now();
    return _control(
        GetBatteryCommand(sequence: _controlSeq.next()), 'get_battery');
  }

  Future<void> _control(ControlMessage message, String label) async {
    try {
      final started = DateTime.now();
      await link.sendControl(message);
      final ackMillis = DateTime.now().difference(started).inMilliseconds;
      _logActivity('$label · acked in $ackMillis ms');
    } catch (e) {
      _logActivity('$label FAILED: $e');
      Log.e(_tag, '$label failed', e);
    }
    notifyListeners();
  }

  void toggleLiveMonitor() {
    liveMonitor = !liveMonitor;
    notifyListeners();
  }

  // --- misc ---

  void _logActivity(String message) {
    activityLog.insert(0, CompanionLogEntry(message));
    if (activityLog.length > _maxLogEntries) {
      activityLog.removeRange(_maxLogEntries, activityLog.length);
    }
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reassembler.reset();
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    link.removeListener(notifyListeners);
    link.dispose();
    if (_playbackReady) {
      unawaited(FlutterPcmSound.release());
    }
    super.dispose();
  }
}
