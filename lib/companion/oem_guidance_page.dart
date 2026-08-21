// One-time keep-alive guidance for vivo/iQOO phones. Their stock cleaner
// FORCE-STOPS backgrounded apps (verified on the iQOO Neo 10 via
// ApplicationExitInfo: "stop ... due to single-cleaner"), including on an
// individual swipe from Recents — which a locked Recents card does NOT
// prevent (measured via adb; the lock only protects against "clean all").
//
// The one fix that actually survives the swipe is Notification access: the
// system keeps a persistent bind to an enabled notification listener and
// re-binds it after the kill, restarting the app and reviving the service
// (this is how Nothing X survives the same cleaner). It is also a real
// feature — phone alerts shown on the bot — so it leads this page. The vivo
// settings below it are hardening, not the cure. Shown automatically once
// per install after an unexpected service death (CompanionController), and
// reachable any time via "Keep-alive tips" on the service card.

import 'package:flutter/material.dart';

import 'companion_controller.dart';

class OemGuidancePage extends StatelessWidget {
  const OemGuidancePage({super.key, required this.controller});

  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Keep the bot alive')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'This phone stops the bot in the background',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'vivo and iQOO phones ship a battery "cleaner" that force-stops '
              'apps — even swiping Cute Bot away in Recents kills it. '
              'One permission fixes this: with Notification access, Android '
              'itself brings Cute Bot back after the cleaner strikes, and '
              'the bot can show your phone\'s alerts with a blink and a '
              'chirp.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _notificationAccessCard(context),
            const SizedBox(height: 8),
            Text('Extra hardening', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const _Step(
              number: 1,
              icon: Icons.home_outlined,
              title: 'Leave with Home, not a swipe',
              body: 'Swiping Cute Bot away in Recents force-stops it on this '
                  'phone (locking the card does not prevent an individual '
                  'swipe). Just press Home instead.',
            ),
            const _Step(
              number: 2,
              icon: Icons.lock_outline,
              title: 'Lock the app in Recents',
              body: 'Pull down on the Cute Bot card in Recents (or '
                  'long-press it) and tap the lock icon. This protects '
                  'against "clean all" — though not against swiping the '
                  'card away individually.',
            ),
            const _Step(
              number: 3,
              icon: Icons.play_circle_outline,
              title: 'Allow autostart',
              body: 'Settings → Apps → Cute Bot → turn on Autostart '
                  '(on some models: i Manager → App manager → Autostart '
                  'manager).',
            ),
            const _Step(
              number: 4,
              icon: Icons.battery_charging_full_outlined,
              title: 'Allow high background power use',
              body: 'Settings → Battery → Background power consumption '
                  'management → Cute Bot → allow high background power '
                  'consumption.',
            ),
            const SizedBox(height: 8),
            _batteryCard(context),
            if (!controller.companionLink.state.associated) ...[
              const SizedBox(height: 8),
              _cdmReminderCard(context),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  /// The primary fix. Cute Bot never reads notification content — only
  /// "something alert-worthy arrived" crosses to the bot.
  Widget _notificationAccessCard(BuildContext context) {
    final theme = Theme.of(context);
    final granted = controller.notificationAccessGranted;
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_active_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('The fix: allow Notification access',
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Cute Bot needs Notification access to show phone alerts on '
              'the robot (LED blink + chirp for WhatsApp, calls, and other '
              'notifications). It also keeps the companion running: Android '
              'reconnects apps with this access after the phone kills '
              'background apps.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (granted)
              const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Notification access is on. The bot shows '
                        'phone alerts and survives the cleaner.'),
                  ),
                ],
              )
            else
              FilledButton(
                onPressed: controller.openNotificationAccessSettings,
                child: const Text('Open Notification access settings'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _batteryCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('And one we can do from here',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (controller.batteryOptimizationExempt)
              const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Battery optimization is already '
                        'off for Cute Bot.'),
                  ),
                ],
              )
            else ...[
              const Text('Exempt Cute Bot from Android battery optimization '
                  '(shows a system dialog).'),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: controller.requestBatteryExemption,
                child: const Text('Allow background'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Shown when the CDM association is gone (a cleaner force-stop can wipe
  /// it — seen as "pkg-data-cleared" on the iQOO). Re-linking restores
  /// wake-on-approach: Android starts the companion when the bot comes
  /// into Bluetooth range.
  Widget _cdmReminderCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.link_off, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Re-link the bot to Android',
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The bot is not linked to Android right now (the phone\'s '
              'cleaner can clear the link). Use "Link bot to Android" on '
              'the Companion page so Android wakes the companion whenever '
              'the bot comes into range.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
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
            CircleAvatar(
              radius: 14,
              child: Text('$number'),
            ),
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
