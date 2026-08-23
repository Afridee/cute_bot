// First-run Companion setup. Sits in front of the debug panel until the
// blocking essentials are true. Copy and order: Docs/companion-setup.md.

import 'package:flutter/material.dart';

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
    final theme = Theme.of(context);
    final step = _display;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up Companion'),
        leading: _canGoBack
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _goBack,
              )
            : null,
      ),
      body: ListenableBuilder(
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
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      Text(_title(step), style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(_body(step), style: theme.textTheme.bodyMedium),
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
          SizedBox(height: 16),
          _KeepAliveStep(
            number: 1,
            icon: Icons.home_outlined,
            title: 'Leave with Home, not a swipe',
            body:
                'Swiping Cute Bot away in Recents force-stops it on this phone '
                '(locking the card does not prevent an individual swipe). '
                'Just press Home instead.',
          ),
          _KeepAliveStep(
            number: 2,
            icon: Icons.lock_outline,
            title: 'Lock Cute Bot in Recents',
            body: 'Pull down on the Cute Bot card in Recents (or long-press '
                'it) and tap the lock icon.',
          ),
          _KeepAliveStep(
            number: 3,
            icon: Icons.play_circle_outline,
            title: 'Allow autostart',
            body: 'Settings → Apps → Cute Bot → Autostart (or i Manager → '
                'Autostart manager).',
          ),
          _KeepAliveStep(
            number: 4,
            icon: Icons.battery_charging_full_outlined,
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
        FilledButton(onPressed: _goForward, child: const Text('Continue')),
      ];
    }

    switch (step) {
      case CompanionSetupStep.welcome:
        return [
          FilledButton(
            onPressed: () async {
              await _c.markWelcomeSeen();
              setState(() => _viewing = null);
            },
            child: const Text('Continue'),
          ),
        ];
      case CompanionSetupStep.notifications:
        return [
          if (_c.notificationPermanentlyDenied || !_c.notificationsGranted)
            OutlinedButton(
              onPressed: _c.openAppSettings,
              child: const Text('Open app settings'),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _c.notificationsGranted ? null : _c.requestNotifications,
            child: const Text('Allow notifications'),
          ),
        ];
      case CompanionSetupStep.bluetooth:
        final needRadio = _c.bleAuthorized && !_c.bluetoothOn;
        return [
          FilledButton(
            onPressed: needRadio ? _c.openBluetoothSettings : _c.requestBle,
            child: Text(
                needRadio ? 'Turn on Bluetooth' : 'Allow Bluetooth'),
          ),
        ];
      case CompanionSetupStep.battery:
        return [
          FilledButton(
            onPressed:
                _c.batteryOptimizationExempt ? null : _c.requestBatteryExemption,
            child: const Text('Allow background'),
          ),
        ];
      case CompanionSetupStep.notificationAccess:
        return [
          FilledButton(
            onPressed: _c.notificationAccessGranted
                ? null
                : _c.openNotificationAccessSettings,
            child: const Text('Open Notification access settings'),
          ),
        ];
      case CompanionSetupStep.oemKeepAlive:
        return [
          OutlinedButton(
            onPressed: _c.skipOemKeepAlive,
            child: const Text('I’ll do this later'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _c.acknowledgeOemKeepAlive,
            child: const Text('I did this'),
          ),
        ];
      case CompanionSetupStep.cdmLink:
        final link = _c.companionLink;
        return [
          OutlinedButton(
            onPressed: _c.skipCdm,
            child: const Text('I’ll do this later'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: link.associating ? null : link.associate,
            child: Text(link.associating ? 'Choosing…' : 'Link bot to Android'),
          ),
          if (link.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                link.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
    final theme = Theme.of(context);
    final s = controller.snapshot;
    final percent = s?.downloadPercent;
    final error = s?.brainError;
    final warming = s?.brainState == BrainSessionState.warming;
    final ready = s != null && companionBrainIsReady(s.brainState);

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ready)
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                Text('Ready', style: theme.textTheme.titleMedium),
              ],
            )
          else if (error != null) ...[
            Text(error, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: controller.retryBrain,
              child: const Text('Retry'),
            ),
          ] else if (percent != null) ...[
            Text(downloadProgressLabel(percent, s?.downloadRemainingSec)),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: percent / 100),
          ] else if (warming) ...[
            const Text('Loading…'),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ] else ...[
            const Text('Waiting for the service to start the download…'),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

class _KeepAliveStep extends StatelessWidget {
  const _KeepAliveStep({
    required this.number,
    required this.icon,
    required this.title,
    required this.body,
  });

  final int number;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(radius: 14, child: Text('$number')),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(title, style: theme.textTheme.titleSmall),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(body, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
