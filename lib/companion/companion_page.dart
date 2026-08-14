// Companion (central) debug panel — M1. Plain and functional: connection
// state, bandwidth-gate numbers, control command buttons, activity log.
// Pretty comes later (the brief says so).

import 'package:flutter/material.dart';

import '../shared/ble_protocol.dart';
import 'bot_link.dart';
import 'companion_controller.dart';

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
          return Column(
            children: [
              if (c.link.lastError != null)
                _ErrorBanner(message: c.link.lastError!),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _LinkCard(controller: c),
                    const SizedBox(height: 12),
                    _ReceiveCard(controller: c),
                    const SizedBox(height: 12),
                    _ControlCard(controller: c),
                    const SizedBox(height: 12),
                    _ActivityCard(controller: c),
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
      content: Text(message),
      actions: const [SizedBox.shrink()],
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final link = controller.link;
    final ready = link.state == BotLinkState.ready;
    final stateLabel = switch (link.state) {
      BotLinkState.idle => 'Idle',
      BotLinkState.bluetoothOff => 'Bluetooth is off',
      BotLinkState.unauthorized => 'Permission denied',
      BotLinkState.unsupported => 'BLE unsupported',
      BotLinkState.scanning => 'Scanning for bot…',
      BotLinkState.connecting => 'Connecting…',
      BotLinkState.configuring => 'Configuring (MTU, GATT)…',
      BotLinkState.ready => 'Connected',
      BotLinkState.reconnectWait =>
        'Reconnecting (attempt ${link.reconnectAttempt})…',
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
                  _Chip(label: 'MTU ${link.mtu}', ok: link.mtu >= 171),
                  if (link.botId != null)
                    _Chip(label: 'Bot …${link.botId}', ok: true),
                  if (link.rssi != null)
                    _Chip(label: '${link.rssi} dBm', ok: true),
                ],
                _Chip(
                  label: 'Bot state: ${controller.botState.name}',
                  ok: true,
                ),
              ],
            ),
            if (controller.battery != null) ...[
              const SizedBox(height: 8),
              Text(
                'Battery ${controller.battery!.percent}% · '
                '${controller.battery!.millivolts} mV'
                '${controller.battery!.charging ? ' · charging' : ''}'
                '${controller.batteryRttMillis != null ? ' · RTT ${controller.batteryRttMillis} ms' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
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

class _ReceiveCard extends StatelessWidget {
  const _ReceiveCard({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final stats = c.lastReceive;
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
                  value: c.liveMonitor,
                  onChanged: (_) => c.toggleLiveMonitor(),
                ),
              ],
            ),
            if (c.receivingUtterance)
              Text('Receiving… ${c.framesThisUtterance} frames')
            else if (stats == null)
              const Text('No utterance received yet. '
                  'Hold-to-talk on the simulator phone.')
            else ...[
              // The bandwidth-gate readout. rate >= 1x RT passes.
              Text(
                '${stats.realTimeRate.toStringAsFixed(2)}x real time · '
                '${stats.kbps.toStringAsFixed(0)} kbps',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: stats.realTimeRate >= 1.0
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
              ),
              Text('${stats.audioMillis} ms audio in ${stats.wallMillis} ms '
                  '· worst frame gap ${stats.maxInterFrameGapMillis} ms'),
              Text(
                '${stats.result.framesReceived} frames, '
                '${stats.result.framesLost} lost, '
                '${stats.result.duplicateFrames} dup, '
                '${stats.result.staleFrames} stale '
                '· crc ${stats.result.checksumHex}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed:
                      c.lastUtterancePcm != null ? c.playLastUtterance : null,
                  child: const Text('Replay'),
                ),
                FilledButton.tonal(
                  onPressed: c.lastUtterancePcm != null &&
                          !c.echoing &&
                          c.link.state == BotLinkState.ready
                      ? c.echoToBot
                      : null,
                  child: Text(c.echoing ? 'Echoing…' : 'Echo to bot'),
                ),
              ],
            ),
            if (c.lastEcho != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Last echo: ${c.lastEcho!.audioMillis} ms audio sent in '
                  '${c.lastEcho!.wallMillis} ms '
                  '(${c.lastEcho!.realTimeRate.toStringAsFixed(2)}x RT)',
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
  const _ControlCard({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final enabled = c.link.state == BotLinkState.ready;
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

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.activityLog;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Activity', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (entries.isEmpty)
              const Text('Nothing yet.')
            else
              for (final entry in entries.take(20))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${entry.timestamp.toIso8601String().substring(11, 19)}  '
                    '${entry.message}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
