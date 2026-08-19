// Companion debug panel — M2 shape. Everything shown here is rendered from
// the latest ServiceSnapshot pushed by the foreground service; the page
// holds no bot state of its own. Plain and functional; pretty comes later.

import 'package:flutter/material.dart';

import '../shared/ble_protocol.dart';
import 'bot_link.dart';
import 'brain/brain_session.dart';
import 'brain/transcript.dart';
import 'companion_controller.dart';
import 'service/service_ipc.dart';

class CompanionPage extends StatefulWidget {
  const CompanionPage({super.key});

  @override
  State<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends State<CompanionPage> {
  late final CompanionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CompanionController();
    _controller.start();
  }

  @override
  void dispose() {
    // The controller detaches from the service; the service keeps running.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Companion (central)')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          final s = c.snapshot;
          return Column(
            children: [
              if (c.phaseError != null) _ErrorBanner(message: c.phaseError!),
              if (s?.linkError != null) _ErrorBanner(message: s!.linkError!),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _ServiceCard(controller: c),
                    if (s != null) ...[
                      const SizedBox(height: 12),
                      _LinkCard(snapshot: s),
                      const SizedBox(height: 12),
                      _BrainCard(controller: c, snapshot: s),
                      const SizedBox(height: 12),
                      _AudioCard(controller: c, snapshot: s),
                      const SizedBox(height: 12),
                      _ControlCard(controller: c, snapshot: s),
                      const SizedBox(height: 12),
                      _TranscriptCard(controller: c, snapshot: s),
                      const SizedBox(height: 12),
                      _ActivityCard(snapshot: s),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      content: Text(
        message,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      actions: const [SizedBox.shrink()],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(
        ok ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: ok ? Colors.green : scheme.outline,
      ),
      label: Text(label),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final phaseLabel = switch (c.phase) {
      CompanionUiPhase.idle => 'Idle',
      CompanionUiPhase.requestingPermissions => 'Requesting permissions…',
      CompanionUiPhase.permissionDenied => 'Bluetooth permission denied',
      CompanionUiPhase.startingService => 'Starting service…',
      CompanionUiPhase.running => 'Service running',
      CompanionUiPhase.stopped => 'Service stopped',
    };
    final running = c.phase == CompanionUiPhase.running;
    final snapshotAge = c.lastSnapshotAt == null
        ? null
        : DateTime.now().difference(c.lastSnapshotAt!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Foreground service',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(label: phaseLabel, ok: running),
                _Chip(
                  label: c.batteryOptimizationExempt
                      ? 'Battery: unrestricted'
                      : 'Battery: restricted',
                  ok: c.batteryOptimizationExempt,
                ),
                if (snapshotAge != null)
                  _Chip(
                    label: 'Snapshot ${snapshotAge.inSeconds}s ago',
                    ok: snapshotAge.inSeconds < 10,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (!c.batteryOptimizationExempt)
                  FilledButton.tonal(
                    onPressed: c.requestBatteryExemption,
                    child: const Text('Allow background'),
                  ),
                if (running)
                  OutlinedButton(
                    onPressed: c.stopService,
                    child: const Text('Stop service'),
                  )
                else
                  FilledButton(
                    onPressed: c.restartService,
                    child: const Text('Start service'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.snapshot});
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final ready = s.linkState == BotLinkState.ready;
    final stateLabel = switch (s.linkState) {
      BotLinkState.idle => 'Idle',
      BotLinkState.bluetoothOff => 'Bluetooth is off',
      BotLinkState.unauthorized => 'Permission missing',
      BotLinkState.unsupported => 'BLE unsupported',
      BotLinkState.scanning => 'Scanning for bot…',
      BotLinkState.connecting => 'Connecting…',
      BotLinkState.configuring => 'Configuring (MTU, GATT)…',
      BotLinkState.ready => 'Connected',
      BotLinkState.reconnectWait =>
        'Reconnecting (attempt ${s.reconnectAttempt})…',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Link', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(label: stateLabel, ok: ready),
                if (ready) ...[
                  _Chip(label: 'MTU ${s.mtu}', ok: s.mtu >= 171),
                  if (s.botId != null)
                    _Chip(label: 'Bot …${s.botId}', ok: true),
                  if (s.rssi != null) _Chip(label: '${s.rssi} dBm', ok: true),
                ],
                _Chip(label: 'Bot state: ${s.botState.name}', ok: true),
              ],
            ),
            if (s.batteryPercent != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Battery ${s.batteryPercent}% · ${s.batteryMillivolts} mV',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BrainCard extends StatelessWidget {
  const _BrainCard({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final stateLabel = switch (s.brainState) {
      BrainSessionState.cold => 'Cold',
      BrainSessionState.warming => 'Warming up…',
      BrainSessionState.ready => 'Ready',
      BrainSessionState.thinking => 'Thinking…',
      BrainSessionState.responding => 'Responding…',
    };
    final busy = s.brainState == BrainSessionState.thinking ||
        s.brainState == BrainSessionState.responding;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Brain (FakeBrain — real model lands in M3)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(
                    label: stateLabel,
                    ok: s.brainState == BrainSessionState.ready || busy),
                _Chip(
                    label: 'Replayed ${s.replayedEntries} entries',
                    ok: true),
                if (s.droppedUtterances > 0)
                  _Chip(label: '${s.droppedUtterances} dropped', ok: false),
              ],
            ),
            if (s.brainError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Error: ${s.brainError}',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ),
            if (s.responseText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('“${s.responseText}…”',
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: s.brainState == BrainSessionState.ready
                      ? controller.simulateUtterance
                      : null,
                  child: const Text('Fake utterance'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioCard extends StatelessWidget {
  const _AudioCard({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final stats = s.lastReceive;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Audio from bot',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                const Text('Live'),
                Switch(
                  value: s.liveMonitor,
                  onChanged: (_) => controller.toggleLiveMonitor(),
                ),
              ],
            ),
            if (s.receivingUtterance)
              const Text('Receiving…')
            else if (stats == null)
              const Text('No utterance received yet. '
                  'Hold-to-talk on the simulator phone.')
            else ...[
              Text(
                '${stats.realTimeRate.toStringAsFixed(2)}x real time',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: stats.realTimeRate >= 1.0
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
              ),
              Text('${stats.audioMillis} ms audio in ${stats.wallMillis} ms'),
              Text(
                '${stats.frames} frames, ${stats.framesLost} lost '
                '· crc ${stats.checksumHex}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: stats != null &&
                          s.linkState == BotLinkState.ready
                      ? controller.echoLastUtterance
                      : null,
                  child: const Text('Echo to bot'),
                ),
              ],
            ),
            if (s.lastEcho != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Last echo: ${s.lastEcho!.audioMillis} ms audio in '
                  '${s.lastEcho!.wallMillis} ms '
                  '(${s.lastEcho!.realTimeRate.toStringAsFixed(2)}x RT)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ControlCard extends StatelessWidget {
  const _ControlCard({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final enabled = snapshot.linkState == BotLinkState.ready;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Control', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _LedButton(
                    color: Colors.red,
                    onPressed: enabled
                        ? () => c.setLed(255, 0, 0, LedPattern.solid)
                        : null),
                _LedButton(
                    color: Colors.green,
                    onPressed: enabled
                        ? () => c.setLed(0, 255, 0, LedPattern.breathe)
                        : null),
                _LedButton(
                    color: Colors.blue,
                    onPressed: enabled
                        ? () => c.setLed(0, 0, 255, LedPattern.blink)
                        : null),
                _LedButton(
                    color: Colors.black26,
                    label: 'off',
                    onPressed: enabled
                        ? () => c.setLed(0, 0, 0, LedPattern.off)
                        : null),
                FilledButton.tonal(
                  onPressed: enabled ? c.wiggle : null,
                  child: const Text('Wiggle'),
                ),
                FilledButton.tonal(
                  onPressed:
                      enabled ? () => c.playSound(BotSound.beep) : null,
                  child: const Text('Beep'),
                ),
                FilledButton.tonal(
                  onPressed: enabled ? c.getBattery : null,
                  child: const Text('Battery'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LedButton extends StatelessWidget {
  const _LedButton({required this.color, this.label, this.onPressed});
  final Color color;
  final String? label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      label: Text(label ?? 'LED'),
    );
  }
}

class _TranscriptCard extends StatelessWidget {
  const _TranscriptCard({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final entries = snapshot.transcript;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Transcript (persisted)',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: entries.isEmpty ? null : controller.clearTranscript,
                  child: const Text('Clear'),
                ),
              ],
            ),
            if (entries.isEmpty)
              const Text('Empty. It survives kills and reboots once filled.')
            else
              for (final entry in entries.reversed.take(12))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${entry.timestamp.toIso8601String().substring(11, 19)} '
                    '${switch (entry.role) {
                      TranscriptRole.user => 'you',
                      TranscriptRole.bot => 'bot',
                      TranscriptRole.system => 'sys',
                    }}: ${entry.text}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.snapshot});
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final lines = snapshot.activity;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Service activity',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (lines.isEmpty)
              const Text('Nothing yet.')
            else
              for (final line in lines.take(20))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(line,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
          ],
        ),
      ),
    );
  }
}
