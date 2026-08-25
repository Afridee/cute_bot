// First-run Companion setup. Sits in front of the debug panel until the
// blocking essentials are true. Copy and order: Docs/companion-setup.md.

import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../brain/brain_session.dart';
import '../brain/model_download.dart';
import '../companion_controller.dart';
import 'companion_setup.dart';

class CompanionSetupPage extends StatefulWidget {
  const CompanionSetupPage({super.key, required this.controller});

  final CompanionController controller;

  @override
  State<CompanionSetupPage> createState() => _CompanionSetupPageState();
}

class _CompanionSetupPageState extends State<CompanionSetupPage> {
  /// User-chosen earlier step (Back). Null means "show the resolved step".
  CompanionSetupStep? _viewing;

  CompanionController get _c => widget.controller;

  CompanionSetupStep get _resolved => _c.setupStep;

  CompanionSetupStep get _display {
    final resolved = _resolved;
    if (resolved == CompanionSetupStep.done) return resolved;
    final viewing = _viewing;
    if (viewing == null || viewing.index > resolved.index) return resolved;
    return viewing;
  }

  List<CompanionSetupStep> get _trail => companionSetupTrail(_c.setupFacts);

  bool get _canGoBack {
    final trail = _trail;
    final i = trail.indexOf(_display);
    return i > 0;
  }

  void _goBack() {
    final trail = _trail;
    final i = trail.indexOf(_display);
    if (i <= 0) return;
    setState(() => _viewing = trail[i - 1]);
  }

  void _goForward() {
    final resolved = _resolved;
    if (resolved == CompanionSetupStep.done) return;
    final trail = _trail;
    final i = trail.indexOf(_display);
    if (i < 0 || i >= trail.length - 1) {
      setState(() => _viewing = null);
      return;
    }
    final next = trail[i + 1];
    setState(() => _viewing = next.index > resolved.index ? null : next);
  }

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final step = _display;
    final trail = _trail;
    final index = trail.indexOf(step);
    final indexLabel = index < 0
        ? ''
        : '${(index + 1).toString().padLeft(2, '0')} / '
            '${trail.length.toString().padLeft(2, '0')}';

    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            // Facts changed (resume from settings): drop a stale viewing
            // step that is now ahead of the first failure.
            if (_viewing != null && _viewing!.index > _resolved.index) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _viewing = null);
              });
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                CuteBotSpace.lg,
                CuteBotSpace.md,
                CuteBotSpace.lg,
                CuteBotSpace.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (_canGoBack) ...[
                        NdBackButton(onPressed: _goBack),
                        const SizedBox(width: CuteBotSpace.md),
                      ],
                      const NdLabel('Set up'),
                      const Spacer(),
                      if (indexLabel.isNotEmpty)
                        Text(indexLabel, style: nd.typography.label),
                    ],
                  ),
                  const SizedBox(height: CuteBotSpace.xl),
                  Expanded(
                    child: ListView(
                      children: [
                        Text(_title(step), style: nd.typography.heading),
                        const SizedBox(height: CuteBotSpace.sm),
                        Text(
                          _body(step),
                          style: nd.typography.body
                              .copyWith(color: nd.colors.textSecondary),
                        ),
                        ..._extras(context, step),
                      ],
                    ),
                  ),
                  ..._actions(context, step),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _title(CompanionSetupStep step) => switch (step) {
        CompanionSetupStep.welcome => 'Before the bot can live here',
        CompanionSetupStep.notifications => 'Show that the bot is running',
        CompanionSetupStep.bluetooth => 'Talk to the bot',
        CompanionSetupStep.battery => 'Don’t let Android starve it',
        CompanionSetupStep.notificationAccess =>
          'Bring the bot back after a kill',
        CompanionSetupStep.oemKeepAlive => 'Allow autostart on this phone',
        CompanionSetupStep.cdmLink => 'Link the bot to Android',
        CompanionSetupStep.brain => 'Download the brain',
        CompanionSetupStep.done => 'Ready',
      };

  String _body(CompanionSetupStep step) => switch (step) {
        CompanionSetupStep.welcome =>
          'Cute Bot thinks on this phone, not in the robot. These steps let '
              'it talk over Bluetooth, keep the brain warm, and come back if '
              'Android kills the app.',
        CompanionSetupStep.notifications =>
          'Android hides background apps unless we can show a quiet '
              'notification. That notification is how you know Cute Bot is '
              'still alive. It never buzzes.',
        CompanionSetupStep.bluetooth =>
          'The robot has no brain of its own. Bluetooth is the only link.',
        CompanionSetupStep.battery =>
          'Battery savers kill the companion even when it is in the '
              'foreground-service list. Allow unrestricted background use.',
        CompanionSetupStep.notificationAccess =>
          'Some phones force-stop apps, including a swipe from Recents. '
              'Notification access is how Android itself restarts Cute Bot. '
              'It also lets the bot blink and chirp when your phone gets an '
              'alert. Cute Bot never reads the text — only that something '
              'arrived.',
        CompanionSetupStep.oemKeepAlive =>
          'vivo and iQOO also need Autostart on, and the Cute Bot card '
              'locked in Recents. Android does not tell us whether you did '
              'this — continue after you have, or skip for now.',
        CompanionSetupStep.cdmLink =>
          'Link once so Android notices the bot when it comes into range '
              'and starts the companion — even if the app is dead. Turn on '
              'the bot (or the Bot Simulator) and keep it nearby.',
        CompanionSetupStep.brain =>
          'About 2.6 GB, once, stays on this phone. Use Wi-Fi. First time '
              'takes several minutes. After that, restarts only reload.',
        CompanionSetupStep.done => 'Companion is ready.',
      };

  List<Widget> _extras(BuildContext context, CompanionSetupStep step) {
    switch (step) {
      case CompanionSetupStep.oemKeepAlive:
        return const [
          SizedBox(height: CuteBotSpace.xl),
          _KeepAliveStep(
            number: 1,
            title: 'Leave with Home, not a swipe',
            body:
                'Swiping Cute Bot away in Recents force-stops it on this phone '
                '(locking the card does not prevent an individual swipe). '
                'Just press Home instead.',
          ),
          _KeepAliveStep(
            number: 2,
            title: 'Lock Cute Bot in Recents',
            body: 'Pull down on the Cute Bot card in Recents (or long-press '
                'it) and tap the lock icon.',
          ),
          _KeepAliveStep(
            number: 3,
            title: 'Allow autostart',
            body: 'Settings → Apps → Cute Bot → Autostart (or i Manager → '
                'Autostart manager).',
          ),
          _KeepAliveStep(
            number: 4,
            title: 'Allow high background power use',
            body: 'Settings → Battery → Background power consumption → '
                'Cute Bot → allow high.',
          ),
        ];
      case CompanionSetupStep.brain:
        return [_BrainProgress(controller: _c)];
      default:
        return const [];
    }
  }

  List<Widget> _actions(BuildContext context, CompanionSetupStep step) {
    final reviewing = step != _resolved && step != CompanionSetupStep.done;
    if (reviewing) {
      return [
        NdButton.primary(label: 'Continue', expand: true, onPressed: _goForward),
      ];
    }

    switch (step) {
      case CompanionSetupStep.welcome:
        return [
          NdButton.primary(
              label: 'Continue',
              expand: true,
              onPressed: () async {
                await _c.markWelcomeSeen();
                setState(() => _viewing = null);
              },
            ),
        ];
      case CompanionSetupStep.notifications:
        return [
          if (_c.notificationPermanentlyDenied || !_c.notificationsGranted)
            NdButton.secondary(
              label: 'Open app settings',
              expand: true,
              onPressed: _c.openAppSettings,
            ),
          if (_c.notificationPermanentlyDenied || !_c.notificationsGranted)
            const SizedBox(height: CuteBotSpace.sm),
          NdButton.primary(
            label: 'Allow notifications',
            expand: true,
            onPressed:
                _c.notificationsGranted ? null : _c.requestNotifications,
          ),
        ];
      case CompanionSetupStep.bluetooth:
        final needRadio = _c.bleAuthorized && !_c.bluetoothOn;
        return [
          NdButton.primary(
            label: needRadio ? 'Turn on Bluetooth' : 'Allow Bluetooth',
            expand: true,
            onPressed: needRadio ? _c.openBluetoothSettings : _c.requestBle,
          ),
        ];
      case CompanionSetupStep.battery:
        return [
          NdButton.primary(
            label: 'Allow background',
            expand: true,
            onPressed: _c.batteryOptimizationExempt
                ? null
                : _c.requestBatteryExemption,
          ),
        ];
      case CompanionSetupStep.notificationAccess:
        return [
          NdButton.primary(
            label: 'Open Notification access settings',
            expand: true,
            onPressed: _c.notificationAccessGranted
                ? null
                : _c.openNotificationAccessSettings,
          ),
        ];
      case CompanionSetupStep.oemKeepAlive:
        return [
          NdButton.secondary(
            label: 'I’ll do this later',
            expand: true,
            onPressed: _c.skipOemKeepAlive,
          ),
          const SizedBox(height: CuteBotSpace.sm),
          NdButton.primary(
            label: 'I did this',
            expand: true,
            onPressed: _c.acknowledgeOemKeepAlive,
          ),
        ];
      case CompanionSetupStep.cdmLink:
        final link = _c.companionLink;
        return [
          NdButton.secondary(
            label: 'I’ll do this later',
            expand: true,
            onPressed: _c.skipCdm,
          ),
          const SizedBox(height: CuteBotSpace.sm),
          NdButton.primary(
            label: link.associating ? 'Choosing…' : 'Link bot to Android',
            expand: true,
            onPressed: link.associating ? null : link.associate,
          ),
          if (link.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: CuteBotSpace.sm),
              child: NdStatusText.error(link.lastError!),
            ),
        ];
      case CompanionSetupStep.brain:
        return const [];
      case CompanionSetupStep.done:
        return const [];
    }
  }
}

class _BrainProgress extends StatelessWidget {
  const _BrainProgress({required this.controller});
  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    final s = controller.snapshot;
    final percent = s?.downloadPercent;
    final error = s?.brainError;
    final warming = s?.brainState == BrainSessionState.warming;
    final ready = s != null && companionBrainIsReady(s.brainState);

    return Padding(
      padding: const EdgeInsets.only(top: CuteBotSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ready) ...[
            Text('READY', style: nd.typography.displayMd),
            const SizedBox(height: CuteBotSpace.sm),
            const NdStatusText.ready(),
          ] else if (error != null) ...[
            NdStatusText.error(error),
            const SizedBox(height: CuteBotSpace.md),
            NdButton.primary(
              label: 'Retry',
              expand: true,
              onPressed: controller.retryBrain,
            ),
          ] else if (percent != null) ...[
            Text(
              '$percent%',
              style: nd.typography.displayMd,
            ),
            const SizedBox(height: CuteBotSpace.sm),
            Text(
              downloadProgressLabel(percent, s?.downloadRemainingSec),
              style: nd.typography.body.copyWith(color: nd.colors.textSecondary),
            ),
            const SizedBox(height: CuteBotSpace.md),
            NdSegmentedProgress(value: percent / 100, height: 16),
          ] else ...[
            const NdStatusText.loading(),
            const SizedBox(height: CuteBotSpace.md),
            NdSegmentedProgress(
              value: warming ? 0.15 : 0,
              height: 16,
            ),
            if (!warming) ...[
              const SizedBox(height: CuteBotSpace.sm),
              Text(
                'Waiting for the service to start the download…',
                style: nd.typography.body.copyWith(color: nd.colors.textDisabled),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _KeepAliveStep extends StatelessWidget {
  const _KeepAliveStep({
    required this.number,
    required this.title,
    required this.body,
  });

  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Padding(
      padding: const EdgeInsets.only(bottom: CuteBotSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              number.toString().padLeft(2, '0'),
              style: nd.typography.label,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: nd.typography.body),
                const SizedBox(height: CuteBotSpace.xs),
                Text(
                  body,
                  style: nd.typography.bodySm
                      .copyWith(color: nd.colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
