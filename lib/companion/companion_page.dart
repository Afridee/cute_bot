// Companion instrument panel — M2 shape. Everything shown here is rendered
// from the latest ServiceSnapshot pushed by the foreground service; the page
// holds no bot state of its own.

import 'package:flutter/material.dart';

import '../design/design.dart';
import '../shared/ble_protocol.dart';
import 'bot_link.dart';
import 'brain/brain_session.dart';
import 'brain/model_download.dart';
import 'brain/transcript.dart';
import 'companion_controller.dart';
import 'oem_guidance_page.dart';
import 'service/service_ipc.dart';
import 'setup/companion_setup.dart';
import 'setup/companion_setup_page.dart';

class CompanionPage extends StatefulWidget {
  const CompanionPage({super.key});

  @override
  State<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends State<CompanionPage>
    with WidgetsBindingObserver {
  late final CompanionController _controller;
  bool _oemGuidancePushed = false;

  @override
  void initState() {
    super.initState();
    _controller = CompanionController();
    _controller.addListener(_maybeShowOemGuidance);
    _controller.start();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from system settings (Notification access, battery):
    // re-read the native state so the cards update without a restart.
    if (state == AppLifecycleState.resumed) {
      _controller.refreshSetupFacts();
    }
  }

  /// One-time push of the keep-alive guidance after the controller detects
  /// that this phone's cleaner force-stopped the service (vivo/iQOO).
  /// Only after setup unlocks — mid-wizard the OEM step already covers this.
  void _maybeShowOemGuidance() {
    if (_controller.setupStep != CompanionSetupStep.done) return;
    if (!_controller.oemGuidancePending || _oemGuidancePushed) return;
    _oemGuidancePushed = true;
    _controller.markOemGuidanceShown();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => OemGuidancePage(controller: _controller),
      ));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The controller detaches from the service; the service keeps running.
    _controller.removeListener(_maybeShowOemGuidance);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        if (!c.setupFactsLoaded) {
          return const Scaffold(
            body: Center(child: NdStatusText.loading()),
          );
        }
        if (c.setupStep != CompanionSetupStep.done) {
          return CompanionSetupPage(controller: c);
        }
        return _CompanionPanel(controller: c);
      },
    );
  }
}

String _heroWord(CompanionController c) {
  if (c.phaseError != null) return 'ERROR';
  switch (c.phase) {
    case CompanionUiPhase.idle:
    case CompanionUiPhase.stopped:
      return 'STOPPED';
    case CompanionUiPhase.startingService:
      return 'STARTING';
    case CompanionUiPhase.running:
      break;
  }
  final s = c.snapshot;
  if (s == null) return 'WAITING';
  if (s.linkError != null) return 'ERROR';
  switch (s.linkState) {
    case BotLinkState.unauthorized:
      return 'DENIED';
    case BotLinkState.unsupported:
      return 'UNSUPPORTED';
    case BotLinkState.bluetoothOff:
      return 'RADIO OFF';
    case BotLinkState.scanning:
      return 'SCANNING';
    case BotLinkState.connecting:
    case BotLinkState.configuring:
      return 'LINKING';
    case BotLinkState.reconnectWait:
      return 'RECONNECT';
    case BotLinkState.idle:
      return 'IDLE';
    case BotLinkState.ready:
      break;
  }
  return switch (s.brainState) {
    BrainSessionState.thinking => 'THINKING',
    BrainSessionState.responding => 'SPEAKING',
    BrainSessionState.warming => 'WARMING',
    BrainSessionState.cold => 'COLD',
    BrainSessionState.ready => 'CONNECTED',
  };
}

Color _heroColor(BuildContext context, CompanionController c) {
  final nd = context.nd;
  if (c.phaseError != null) return CuteBotSignal.error;
  switch (c.phase) {
    case CompanionUiPhase.idle:
    case CompanionUiPhase.stopped:
      return nd.colors.textSecondary;
    case CompanionUiPhase.startingService:
      return CuteBotSignal.warning;
    case CompanionUiPhase.running:
      break;
  }
  final s = c.snapshot;
  if (s == null) return CuteBotSignal.warning;
  if (s.linkError != null) return CuteBotSignal.error;
  switch (s.linkState) {
    case BotLinkState.unauthorized:
    case BotLinkState.unsupported:
    case BotLinkState.bluetoothOff:
      return CuteBotSignal.error;
    case BotLinkState.scanning:
    case BotLinkState.connecting:
    case BotLinkState.configuring:
    case BotLinkState.reconnectWait:
      return CuteBotSignal.warning;
    case BotLinkState.idle:
      return nd.colors.textSecondary;
    case BotLinkState.ready:
      break;
  }
  switch (s.brainState) {
    case BrainSessionState.thinking:
    case BrainSessionState.responding:
      return nd.colors.textDisplay;
    case BrainSessionState.warming:
    case BrainSessionState.cold:
      return CuteBotSignal.warning;
    case BrainSessionState.ready:
      return CuteBotSignal.success;
  }
}

class _CompanionPanel extends StatelessWidget {
  const _CompanionPanel({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.snapshot;
    final nd = context.nd;
    final heroWord = _heroWord(c);
    final heroColor = _heroColor(context, c);

    return Scaffold(
      body: SafeArea(
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
                  const NdLabel('Companion'),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  CuteBotSpace.lg,
                  CuteBotSpace.xl,
                  CuteBotSpace.lg,
                  CuteBotSpace.xxxl,
                ),
                children: [
                  Text(
                    heroWord,
                    style: nd.typography.displayLg.copyWith(color: heroColor),
                  ),
                  const SizedBox(height: CuteBotSpace.sm),
                  Text(
                    _secondaryLine(c, s),
                    style: nd.typography.body.copyWith(color: nd.colors.textSecondary),
                  ),
                  if (c.phaseError != null) ...[
                    const SizedBox(height: CuteBotSpace.sm),
                    NdStatusText.error(c.phaseError!),
                  ],
                  if (s?.linkError != null) ...[
                    const SizedBox(height: CuteBotSpace.sm),
                    NdStatusText.error(s!.linkError!),
                  ],
                  const SizedBox(height: CuteBotSpace.xl),
                  NdMetricTriple(
                    items: [
                      (
                        'Battery',
                        s?.batteryPercent != null
                            ? '${s!.batteryPercent}'
                            : '—',
                        '%',
                        null,
                      ),
                      (
                        'Rssi',
                        s?.rssi != null ? '${s!.rssi}' : '—',
                        'dBm',
                        null,
                      ),
                      (
                        'Ttf',
                        s?.lastLatency != null
                            ? '${s!.lastLatency!.firstTokenMs}'
                            : '—',
                        'ms',
                        null,
                      ),
                    ],
                  ),
                  if (s?.downloadPercent != null) ...[
                    const SizedBox(height: CuteBotSpace.xl),
                    NdGroup(
                      label: 'Model',
                      children: [
                        Text(
                          downloadProgressLabel(
                            s!.downloadPercent!,
                            s.downloadRemainingSec,
                          ),
                          style: nd.typography.body,
                        ),
                        const SizedBox(height: CuteBotSpace.sm),
                        NdSegmentedProgress(
                          value: s.downloadPercent! / 100,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: CuteBotSpace.xxl),
                  _ServiceGroup(controller: c),
                  const SizedBox(height: CuteBotSpace.xxl),
                  _AndroidLinkGroup(controller: c),
                  if (s != null) ...[
                    const SizedBox(height: CuteBotSpace.xxl),
                    _LinkGroup(snapshot: s),
                    const SizedBox(height: CuteBotSpace.xxl),
                    _BrainGroup(controller: c, snapshot: s),
                    const SizedBox(height: CuteBotSpace.xxl),
                    _AudioGroup(controller: c, snapshot: s),
                    const SizedBox(height: CuteBotSpace.xxl),
                    _ControlGroup(controller: c, snapshot: s),
                    const SizedBox(height: CuteBotSpace.xxl),
                    _TranscriptGroup(controller: c, snapshot: s),
                    const SizedBox(height: CuteBotSpace.xxl),
                    _ActivityGroup(snapshot: s),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _secondaryLine(CompanionController c, ServiceSnapshot? s) {
    if (s == null) return 'waiting for service snapshot';
    return 'bot ${s.botState.name}  ·  ${s.brainKind}';
  }
}

class _ServiceGroup extends StatelessWidget {
  const _ServiceGroup({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final running = c.phase == CompanionUiPhase.running;
    final snapshotAge = c.lastSnapshotAt == null
        ? null
        : DateTime.now().difference(c.lastSnapshotAt!);
    final phaseLabel = switch (c.phase) {
      CompanionUiPhase.idle => 'Idle',
      CompanionUiPhase.startingService => 'Starting',
      CompanionUiPhase.running => 'Running',
      CompanionUiPhase.stopped => 'Stopped',
    };
    return NdGroup(
      label: 'Service',
      children: [
        NdStatRow(label: 'Phase', value: phaseLabel),
        const NdHairline(),
        NdStatRow(
          label: 'Battery',
          value: c.batteryOptimizationExempt ? 'Unrestricted' : 'Restricted',
          valueColor: c.batteryOptimizationExempt
              ? CuteBotSignal.success
              : CuteBotSignal.warning,
        ),
        const NdHairline(),
        NdStatRow(
          label: 'Alert access',
          value: c.notificationAccessGranted ? 'On' : 'Off',
          valueColor: c.notificationAccessGranted
              ? CuteBotSignal.success
              : context.nd.colors.textSecondary,
        ),
        if (snapshotAge != null) ...[
          const NdHairline(),
          NdStatRow(
            label: 'Snapshot',
            value: '${snapshotAge.inSeconds}',
            unit: 's ago',
            valueColor: snapshotAge.inSeconds < 10
                ? CuteBotSignal.success
                : CuteBotSignal.warning,
          ),
        ],
        if (c.snapshot != null) ...[
          const NdHairline(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Expanded(child: NdLabel('Phone alerts on bot')),
                NdToggle(
                  value: c.snapshot!.phoneAlertsEnabled,
                  onChanged: c.notificationAccessGranted
                      ? c.setPhoneAlerts
                      : null,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: CuteBotSpace.md),
        NdActionWrap(
          children: [
            if (!c.notificationAccessGranted)
              NdButton.secondary(
                label: 'Allow notification access',
                onPressed: c.openNotificationAccessSettings,
              ),
            if (!c.batteryOptimizationExempt)
              NdButton.secondary(
                label: 'Allow background',
                onPressed: c.requestBatteryExemption,
              ),
            if (running)
              NdButton.destructive(
                label: 'Stop service',
                onPressed: c.stopService,
              )
            else
              NdButton.primary(
                label: 'Start service',
                onPressed: c.restartService,
              ),
            if (c.isAggressiveOem)
              NdButton.ghost(
                label: 'Keep-alive tips',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => OemGuidancePage(controller: c),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AndroidLinkGroup extends StatelessWidget {
  const _AndroidLinkGroup({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final link = controller.companionLink;
    final state = link.state;
    return NdGroup(
      label: 'Android link',
      children: [
        NdStatRow(
          label: 'Cdm',
          value: state.associated
              ? (state.addresses.firstOrNull ?? 'Linked')
              : 'Not linked',
          valueColor: state.associated ? CuteBotSignal.success : null,
        ),
        if (state.associated && state.bondState != null) ...[
          const NdHairline(),
          NdStatRow(
            label: 'Pairing',
            value: state.bondState!,
            valueColor:
                state.bondState == 'bonded' ? CuteBotSignal.success : null,
          ),
        ],
        const NdHairline(),
        NdStatRow(
          label: 'Wake on approach',
          value: state.presenceSupported ? 'Supported' : 'Needs Android 12+',
          valueColor: state.presenceSupported && state.associated
              ? CuteBotSignal.success
              : context.nd.colors.textSecondary,
        ),
        if (link.lastError != null) ...[
          const SizedBox(height: CuteBotSpace.sm),
          NdStatusText.error(link.lastError!),
        ],
        const SizedBox(height: CuteBotSpace.md),
        NdActionWrap(
          children: [
            if (!state.associated)
              NdButton.secondary(
                label: link.associating ? 'Choosing…' : 'Link bot to Android',
                onPressed: link.associating ? null : link.associate,
              )
            else
              NdButton.secondary(
                label: 'Remove link',
                onPressed: link.disassociate,
              ),
          ],
        ),
      ],
    );
  }
}

class _LinkGroup extends StatelessWidget {
  const _LinkGroup({required this.snapshot});
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
      BotLinkState.scanning => 'Scanning',
      BotLinkState.connecting => 'Connecting',
      BotLinkState.configuring => 'Configuring',
      BotLinkState.ready => 'Connected',
      BotLinkState.reconnectWait => 'Reconnecting ${s.reconnectAttempt}',
    };
    return NdGroup(
      label: 'Link',
      children: [
        NdStatRow(
          label: 'State',
          value: stateLabel,
          valueColor: ready ? CuteBotSignal.success : null,
        ),
        if (ready) ...[
          const NdHairline(),
          NdStatRow(
            label: 'Mtu',
            value: '${s.mtu}',
            valueColor: s.mtu >= 171 ? CuteBotSignal.success : CuteBotSignal.warning,
          ),
          if (s.botId != null) ...[
            const NdHairline(),
            NdStatRow(label: 'Bot', value: '…${s.botId}'),
          ],
        ],
        const NdHairline(),
        NdStatRow(label: 'Bot state', value: s.botState.name),
        if (s.batteryMillivolts != null) ...[
          const NdHairline(),
          NdStatRow(
            label: 'Millivolts',
            value: '${s.batteryMillivolts}',
            unit: 'mV',
          ),
        ],
      ],
    );
  }
}

class _BrainGroup extends StatelessWidget {
  const _BrainGroup({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final nd = context.nd;
    final stateLabel = switch (s.brainState) {
      BrainSessionState.cold => 'Cold',
      BrainSessionState.warming => 'Warming',
      BrainSessionState.ready => 'Ready',
      BrainSessionState.thinking => 'Thinking',
      BrainSessionState.responding => 'Responding',
    };
    final busy = s.brainState == BrainSessionState.thinking ||
        s.brainState == BrainSessionState.responding;
    return NdGroup(
      label: 'Brain',
      children: [
        NdStatRow(
          label: 'State',
          value: stateLabel,
          valueColor: s.brainState == BrainSessionState.ready || busy
              ? CuteBotSignal.success
              : CuteBotSignal.warning,
        ),
        const NdHairline(),
        NdStatRow(label: 'Kind', value: s.brainKind),
        const NdHairline(),
        NdStatRow(label: 'Replayed', value: '${s.replayedEntries}'),
        if (s.droppedUtterances > 0) ...[
          const NdHairline(),
          NdStatRow(
            label: 'Dropped',
            value: '${s.droppedUtterances}',
            valueColor: CuteBotSignal.error,
          ),
        ],
        if (s.brainError != null) ...[
          const SizedBox(height: CuteBotSpace.sm),
          NdStatusText.error(s.brainError!),
        ],
        if (s.responseText.isNotEmpty) ...[
          const SizedBox(height: CuteBotSpace.md),
          Text(
            s.responseText,
            style: nd.typography.body,
          ),
        ],
        if (s.lastLatency != null) ...[
          const SizedBox(height: CuteBotSpace.sm),
          Text(s.lastLatency!.summary, style: nd.typography.caption),
        ],
        const SizedBox(height: CuteBotSpace.md),
        NdActionWrap(
          children: [
            NdButton.secondary(
              label: 'Fake utterance',
              onPressed: s.brainState == BrainSessionState.ready
                  ? controller.simulateUtterance
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _AudioGroup extends StatelessWidget {
  const _AudioGroup({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final nd = context.nd;
    final stats = s.lastReceive;
    return NdGroup(
      label: 'Audio',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NdLabel('Live'),
          NdToggle(
            value: s.liveMonitor,
            onChanged: (_) => controller.toggleLiveMonitor(),
          ),
        ],
      ),
      children: [
        if (s.receivingUtterance)
          const NdStatusText('[RECEIVING]')
        else if (stats == null)
          Text(
            'No utterance received yet. Hold-to-talk on the simulator phone.',
            style: nd.typography.body.copyWith(color: nd.colors.textSecondary),
          )
        else ...[
          NdStatRow(
            label: 'Rate',
            value: stats.realTimeRate.toStringAsFixed(2),
            unit: '× RT',
            valueColor: stats.realTimeRate >= 1.0
                ? CuteBotSignal.success
                : CuteBotSignal.error,
          ),
          const NdHairline(),
          NdStatRow(
            label: 'Audio',
            value: '${stats.audioMillis}',
            unit: 'ms',
          ),
          const NdHairline(),
          NdStatRow(
            label: 'Wall',
            value: '${stats.wallMillis}',
            unit: 'ms',
          ),
          const NdHairline(),
          NdStatRow(
            label: 'Frames',
            value: '${stats.frames} / ${stats.framesLost} lost',
          ),
          const NdHairline(),
          NdStatRow(label: 'Crc', value: stats.checksumHex),
        ],
        const SizedBox(height: CuteBotSpace.md),
        NdActionWrap(
          children: [
            NdButton.secondary(
              label: 'Echo to bot',
              onPressed: stats != null && s.linkState == BotLinkState.ready
                  ? controller.echoLastUtterance
                  : null,
            ),
          ],
        ),
        if (s.lastEcho != null) ...[
          const SizedBox(height: CuteBotSpace.sm),
          Text(
            'Last echo: ${s.lastEcho!.audioMillis} ms audio in '
            '${s.lastEcho!.wallMillis} ms '
            '(${s.lastEcho!.realTimeRate.toStringAsFixed(2)}x RT)',
            style: nd.typography.caption,
          ),
        ],
      ],
    );
  }
}

class _ControlGroup extends StatelessWidget {
  const _ControlGroup({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final enabled = snapshot.linkState == BotLinkState.ready;
    return NdGroup(
      label: 'Control',
      children: [
        NdActionWrap(
          children: [
            NdLedControl(
              color: const Color(0xFFFF0000),
              label: 'Led',
              onPressed: enabled
                  ? () => c.setLed(255, 0, 0, LedPattern.solid)
                  : null,
            ),
            NdLedControl(
              color: const Color(0xFF00FF00),
              label: 'Led',
              onPressed: enabled
                  ? () => c.setLed(0, 255, 0, LedPattern.breathe)
                  : null,
            ),
            NdLedControl(
              color: const Color(0xFF0000FF),
              label: 'Led',
              onPressed: enabled
                  ? () => c.setLed(0, 0, 255, LedPattern.blink)
                  : null,
            ),
            NdLedControl(
              color: context.nd.colors.borderVisible,
              label: 'Off',
              onPressed: enabled
                  ? () => c.setLed(0, 0, 0, LedPattern.off)
                  : null,
            ),
            NdButton.secondary(
              label: 'Wiggle',
              onPressed: enabled ? c.wiggle : null,
            ),
            NdButton.secondary(
              label: 'Beep',
              onPressed: enabled ? () => c.playSound(BotSound.beep) : null,
            ),
            NdButton.secondary(
              label: 'Battery',
              onPressed: enabled ? c.getBattery : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _TranscriptGroup extends StatelessWidget {
  const _TranscriptGroup({required this.controller, required this.snapshot});
  final CompanionController controller;
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final entries = snapshot.transcript;
    return NdGroup(
      label: 'Transcript',
      trailing: NdButton.ghost(
        label: 'Clear',
        onPressed: entries.isEmpty ? null : controller.clearTranscript,
      ),
      children: [
        if (entries.isEmpty)
          Text(
            'Empty. It survives kills and reboots once filled.',
            style: nd.typography.body.copyWith(color: nd.colors.textDisabled),
          )
        else
          for (final entry in entries.reversed.take(12)) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '${entry.timestamp.toIso8601String().substring(11, 19)}  '
                '${switch (entry.role) {
                  TranscriptRole.user => 'you',
                  TranscriptRole.bot => 'bot',
                  TranscriptRole.system => 'sys',
                }}  ${entry.text}',
                style: nd.typography.caption.copyWith(color: nd.colors.textPrimary),
              ),
            ),
            const NdHairline(),
          ],
      ],
    );
  }
}

class _ActivityGroup extends StatelessWidget {
  const _ActivityGroup({required this.snapshot});
  final ServiceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final lines = snapshot.activity;
    return NdGroup(
      label: 'Activity',
      children: [
        if (lines.isEmpty)
          Text(
            'Nothing yet.',
            style: nd.typography.body.copyWith(color: nd.colors.textDisabled),
          )
        else
          for (final line in lines.take(20)) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                line,
                style: nd.typography.caption.copyWith(color: nd.colors.textPrimary),
              ),
            ),
            const NdHairline(),
          ],
      ],
    );
  }
}
