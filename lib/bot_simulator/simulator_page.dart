// Bot simulator UI. This screen exists to prove the protocol works on two
// phones; the LED eye is the one break in an otherwise rectangular layout.

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    show BluetoothLowEnergyState;
import 'package:flutter/material.dart';

import '../design/design.dart';
import '../shared/ble_protocol.dart';
import 'simulator_controller.dart';
import 'visor/bot_visor.dart';
import 'visor/face_pose.dart';
import 'visor/mood_from_led.dart';

class SimulatorPage extends StatefulWidget {
  const SimulatorPage({super.key});

  @override
  State<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends State<SimulatorPage> {
  late final SimulatorController _controller;

  /// Face view is the default; Tech keeps the full debugging screen.
  bool _friendly = true;

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
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          return Column(
            children: [
              Expanded(
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          CuteBotSpace.lg,
                          CuteBotSpace.md,
                          CuteBotSpace.lg,
                          0,
                        ),
                        child: Row(
                          children: [
                            const NdBackButton(),
                            const SizedBox(width: CuteBotSpace.md),
                            const Expanded(child: NdLabel('Bot simulator')),
                            NdSegmentedControl<bool>(
                              segments: const [(true, 'Face'), (false, 'Tech')],
                              value: _friendly,
                              onChanged: (v) => setState(() => _friendly = v),
                            ),
                          ],
                        ),
                      ),
                      if (c.fatalError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            CuteBotSpace.lg,
                            CuteBotSpace.md,
                            CuteBotSpace.lg,
                            0,
                          ),
                          child: NdStatusText.error(c.fatalError!),
                        ),
                      Expanded(
                        child: _friendly
                            ? _FaceView(controller: c)
                            : ListView(
                                padding: const EdgeInsets.fromLTRB(
                                  CuteBotSpace.lg,
                                  CuteBotSpace.xl,
                                  CuteBotSpace.lg,
                                  CuteBotSpace.xxl,
                                ),
                                children: [
                                  _LedEye(controller: c),
                                  const SizedBox(height: CuteBotSpace.xxl),
                                  _ConversationGroup(controller: c),
                                  const SizedBox(height: CuteBotSpace.xxl),
                                  _LinkGroup(controller: c),
                                  const SizedBox(height: CuteBotSpace.xxl),
                                  _AudioGroup(controller: c),
                                  const SizedBox(height: CuteBotSpace.xxl),
                                  _ActivityGroup(controller: c),
                                ],
                              ),
                      ),
                    ],
                  ),
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

/// User-friendly view: the animated visor is the whole screen. Primary:
/// the face. Secondary: the mood word. Tertiary: link status. Everything
/// else lives in the Tech view.
class _FaceView extends StatelessWidget {
  const _FaceView({required this.controller});
  final SimulatorController controller;

  VisorMood get _mood {
    final c = controller;
    if (c.ledPattern == LedPattern.off) return VisorMood.neutral;
    final recentWiggle = c.lastWiggleAt != null &&
        c.lastLedAt != null &&
        c.lastWiggleAt!.isAfter(c.lastLedAt!);
    return visorMoodForLed(
      red: c.ledRed,
      green: c.ledGreen,
      blue: c.ledBlue,
      pattern: c.ledPattern,
      recentWiggle: recentWiggle,
    );
  }

  String get _status {
    final c = controller;
    if (c.radioState != BluetoothLowEnergyState.poweredOn) {
      return '[BLUETOOTH OFF]';
    }
    if (c.hasConnection) return '[LINKED]';
    if (c.advertising) return '[WAITING FOR COMPANION]';
    return '[OFFLINE]';
  }

  @override
  Widget build(BuildContext context) {
    final mood = _mood;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CuteBotSpace.lg,
        CuteBotSpace.xxl,
        CuteBotSpace.lg,
        CuteBotSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BotVisor(mood: mood, timerDisplay: controller.timerDisplay),
          const SizedBox(height: CuteBotSpace.md),
          Row(
            children: [
              NdLabel(mood == VisorMood.lowBattery ? 'low battery' : mood.name),
              const Spacer(),
              NdStatusText(
                _status,
                color: controller.hasConnection ? CuteBotSignal.success : null,
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _LedEye extends StatelessWidget {
  const _LedEye({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final nd = context.nd;
    final off = c.ledPattern == LedPattern.off;
    final color = off
        ? nd.colors.borderVisible
        : Color.fromARGB(255, c.ledRed, c.ledGreen, c.ledBlue);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedRotation(
          turns: c.wiggleCount * 0.25,
          duration: CuteBotSignal.durationMicro,
          curve: CuteBotSignal.curve,
          child: AnimatedContainer(
            duration: CuteBotSignal.durationMicro,
            curve: CuteBotSignal.curve,
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: nd.colors.borderVisible),
            ),
          ),
        ),
        const SizedBox(height: CuteBotSpace.md),
        NdLabel(c.ledPattern.name),
        const SizedBox(height: CuteBotSpace.xs),
        Text(
          'rgb(${c.ledRed}, ${c.ledGreen}, ${c.ledBlue})  ·  '
          'wiggles ${c.wiggleCount}',
          style: nd.typography.body.copyWith(color: nd.colors.textSecondary),
        ),
      ],
    );
  }
}

class _ConversationGroup extends StatelessWidget {
  const _ConversationGroup({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final lines = controller.conversation;
    return NdGroup(
      label: 'Conversation',
      children: [
        if (lines.isEmpty)
          Text(
            'Hold to talk, then wait for a reply. Captions still stream '
            'over BLE; spoken audio is TTS from the companion.',
            style: nd.typography.body.copyWith(color: nd.colors.textDisabled),
          )
        else
          for (final line in lines) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NdLabel(line.role == SimulatorChatRole.user ? 'You' : 'Bot'),
                  const SizedBox(height: CuteBotSpace.xs),
                  Text(
                    '${line.text}${line.streaming ? ' …' : ''}',
                    style: nd.typography.body,
                  ),
                ],
              ),
            ),
            const NdHairline(),
          ],
      ],
    );
  }
}

class _LinkGroup extends StatelessWidget {
  const _LinkGroup({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final radioOn = c.radioState == BluetoothLowEnergyState.poweredOn;
    return NdGroup(
      label: 'Link',
      children: [
        NdStatRow(
          label: 'Radio',
          value: c.radioState.name,
          valueColor: radioOn ? CuteBotSignal.success : CuteBotSignal.error,
        ),
        const NdHairline(),
        NdStatRow(
          label: 'Advertise',
          value: c.advertising ? kAdvertisedName : 'Off',
          valueColor: c.advertising ? CuteBotSignal.success : null,
        ),
        const NdHairline(),
        NdStatRow(
          label: 'Subscribers',
          value: '${c.subscriberCount}',
          valueColor: c.subscriberCount > 0 ? CuteBotSignal.success : null,
        ),
        const NdHairline(),
        NdStatRow(label: 'Bot state', value: c.botState.name),
        if (c.mtuByCentral.isNotEmpty) ...[
          const NdHairline(),
          NdStatRow(
            label: 'Mtu',
            value: c.mtuByCentral.entries
                .map((e) =>
                    '${e.value} (…${e.key.substring(e.key.length - 8)})')
                .join('  ·  '),
          ),
        ],
      ],
    );
  }
}

class _AudioGroup extends StatelessWidget {
  const _AudioGroup({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return NdGroup(
      label: 'Audio',
      children: [
        NdStatRow(
          label: 'Mic out',
          value: '${c.micFramesSent}',
          unit: c.talking ? 'streaming' : 'frames',
        ),
        const NdHairline(),
        NdStatRow(
          label: 'Speaker in',
          value: '${c.audioFramesReceived}',
          unit: c.receivingAudio ? 'playing' : 'frames',
        ),
        const NdHairline(),
        NdStatRow(
          label: 'Lost',
          value: '${c.audioFramesLost}',
        ),
        const NdHairline(),
        NdStatRow(
          label: 'Wire',
          value:
              '${AudioWireFormat.sampleRate ~/ 1000} kHz · ${AudioWireFormat.codec} · ${AudioWireFormat.millisPerFrame} ms',
        ),
      ],
    );
  }
}

class _ActivityGroup extends StatelessWidget {
  const _ActivityGroup({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final entries = controller.activityLog;
    return NdGroup(
      label: 'Activity',
      children: [
        if (entries.isEmpty)
          Text(
            'Nothing yet.',
            style: nd.typography.body.copyWith(color: nd.colors.textDisabled),
          )
        else
          for (final entry in entries.take(20)) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '${entry.timestamp.toIso8601String().substring(11, 19)}  '
                '${entry.message}',
                style: nd.typography.caption.copyWith(color: nd.colors.textPrimary),
              ),
            ),
            const NdHairline(),
          ],
      ],
    );
  }
}

class _TalkButton extends StatelessWidget {
  const _TalkButton({required this.controller});
  final SimulatorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final nd = context.nd;
    final enabled = c.subscriberCount > 0;
    final talking = c.talking;
    final Color bg;
    final Color fg;
    final String label;
    if (!enabled) {
      bg = Colors.transparent;
      fg = nd.colors.textDisabled;
      label = '[ WAITING FOR SUBSCRIBER ]';
    } else if (talking) {
      bg = CuteBotSignal.accent;
      fg = nd.colors.textDisplay;
      label = 'Holding';
    } else {
      bg = nd.colors.textDisplay;
      fg = nd.colors.canvas;
      label = 'Hold to talk';
    }

    return Material(
      color: nd.colors.canvas,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CuteBotSpace.lg,
            CuteBotSpace.md,
            CuteBotSpace.lg,
            CuteBotSpace.md,
          ),
          child: GestureDetector(
            onTapDown: enabled ? (_) => c.startTalking() : null,
            onTapUp: (_) => c.stopTalking(),
            onTapCancel: () => c.stopTalking(),
            child: AnimatedContainer(
              duration: CuteBotSignal.durationMicro,
              curve: CuteBotSignal.curve,
              height: 56,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(999),
                border: enabled
                    ? null
                    : Border.all(color: nd.colors.borderVisible),
              ),
              alignment: Alignment.center,
              child: Text(
                label.toUpperCase(),
                style: nd.typography.button.copyWith(color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
