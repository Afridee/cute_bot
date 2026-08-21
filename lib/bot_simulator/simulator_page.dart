// Debug-panel UI for the bot simulator. Function over beauty: this screen
// exists to prove the protocol works on two phones, not to be the product.

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    show BluetoothLowEnergyState;
import 'package:flutter/material.dart';

import '../shared/ble_protocol.dart';
import 'simulator_controller.dart';

class SimulatorPage extends StatefulWidget {
  const SimulatorPage({super.key});

  @override
  State<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends State<SimulatorPage> {
  late final SimulatorController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SimulatorController();
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
      appBar: AppBar(title: const Text('Bot Simulator (peripheral)')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          return Column(
            children: [
              if (c.fatalError != null) _ErrorBanner(message: c.fatalError!),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    _StatusCard(controller: c),
                    const SizedBox(height: 12),
                    _LedCard(controller: c),
                    const SizedBox(height: 12),
                    _ConversationCard(controller: c),
                    const SizedBox(height: 12),
                    _AudioCard(controller: c),
                    const SizedBox(height: 12),
                    _ActivityCard(controller: c),
                  ],
                ),
              ),
              _TalkButton(controller: c),
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final radioOn = c.radioState == BluetoothLowEnergyState.poweredOn;
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
                _Chip(
                  label: 'Radio: ${c.radioState.name}',
                  ok: radioOn,
                ),
                _Chip(
                  label: c.advertising
                      ? 'Advertising "$kAdvertisedName"'
                      : 'Not advertising',
                  ok: c.advertising,
                ),
                _Chip(
                  label: 'Audio subscribers: ${c.subscriberCount}',
                  ok: c.subscriberCount > 0,
                ),
                _Chip(label: 'Bot state: ${c.botState.name}', ok: true),
              ],
            ),
            if (c.mtuByCentral.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                c.mtuByCentral.entries
                    .map((e) =>
                        'MTU ${e.value} (…${e.key.substring(e.key.length - 8)})')
                    .join('  ·  '),
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

class _LedCard extends StatelessWidget {
  const _LedCard({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final off = c.ledPattern == LedPattern.off;
    final color = off
        ? Colors.black26
        : Color.fromARGB(255, c.ledRed, c.ledGreen, c.ledBlue);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // The "LED": a colored box, per the milestone spec. Wiggle
            // rotates it briefly so servo commands are visible too.
            AnimatedRotation(
              turns: c.wiggleCount * 0.25,
              duration: const Duration(milliseconds: 300),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: off
                      ? null
                      : [BoxShadow(color: color, blurRadius: 24)],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('LED', style: Theme.of(context).textTheme.titleMedium),
                  Text(
                      'rgb(${c.ledRed}, ${c.ledGreen}, ${c.ledBlue}) — ${c.ledPattern.name}'),
                  Text('wiggles: ${c.wiggleCount}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final lines = controller.conversation;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Conversation', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            if (lines.isEmpty)
              Text(
                'Hold to talk, then wait for a reply. Captions come over BLE '
                'until TTS (M5) speaks them.',
                style: theme.textTheme.bodySmall,
              )
            else
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Align(
                    alignment: line.role == SimulatorChatRole.user
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: line.role == SimulatorChatRole.user
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Text(
                            '${line.role == SimulatorChatRole.user ? 'You' : 'Bot'}'
                            '${line.streaming ? ' …' : ''}\n${line.text}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _AudioCard extends StatelessWidget {
  const _AudioCard({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Audio', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Mic out: ${c.micFramesSent} frames'
                '${c.talking ? ' (streaming…)' : ''}'),
            Text('Speaker in: ${c.audioFramesReceived} frames, '
                '${c.audioFramesLost} lost'
                '${c.receivingAudio ? ' (playing…)' : ''}'),
            Text(
              '${AudioWireFormat.sampleRate ~/ 1000} kHz mono, '
              '${AudioWireFormat.codec}, '
              '${AudioWireFormat.millisPerFrame} ms/frame',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.controller});
  final SimulatorController controller;

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

class _TalkButton extends StatelessWidget {
  const _TalkButton({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final enabled = c.subscriberCount > 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: GestureDetector(
          onTapDown: enabled ? (_) => c.startTalking() : null,
          onTapUp: (_) => c.stopTalking(),
          onTapCancel: () => c.stopTalking(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 72,
            decoration: BoxDecoration(
              color: !enabled
                  ? scheme.surfaceContainerHighest
                  : (c.talking ? scheme.error : scheme.primary),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Center(
              child: Text(
                !enabled
                    ? 'Waiting for an audio subscriber…'
                    : (c.talking ? 'Streaming mic — release to end' : 'Hold to talk'),
                style: TextStyle(
                  color: enabled ? scheme.onPrimary : scheme.outline,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
