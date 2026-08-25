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

import '../design/design.dart';
import 'companion_controller.dart';

class OemGuidancePage extends StatelessWidget {
  const OemGuidancePage({super.key, required this.controller});

  final CompanionController controller;

  @override
  Widget build(BuildContext context) {
    final nd = context.nd;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  CuteBotSpace.lg,
                  CuteBotSpace.md,
                  CuteBotSpace.lg,
                  0,
                ),
                child: const Row(
                  children: [
                    NdBackButton(),
                    SizedBox(width: CuteBotSpace.md),
                    NdLabel('Keep the bot alive'),
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
                      'This phone stops the bot in the background',
                      style: nd.typography.heading,
                    ),
                    const SizedBox(height: CuteBotSpace.sm),
                    Text(
                      'vivo and iQOO phones ship a battery "cleaner" that '
                      'force-stops apps — even swiping Cute Bot away in Recents '
                      'kills it. One permission fixes this: with Notification '
                      'access, Android itself brings Cute Bot back after the '
                      'cleaner strikes, and the bot can show your phone\'s '
                      'alerts with a blink and a chirp.',
                      style: nd.typography.body
                          .copyWith(color: nd.colors.textSecondary),
                    ),
                    const SizedBox(height: CuteBotSpace.xxl),
                    _notificationAccessBlock(context),
                    const SizedBox(height: CuteBotSpace.xxl),
                    const NdLabel('Extra hardening'),
                    const SizedBox(height: CuteBotSpace.md),
                    const _Step(
                      number: 1,
                      title: 'Leave with Home, not a swipe',
                      body:
                          'Swiping Cute Bot away in Recents force-stops it on this '
                          'phone (locking the card does not prevent an individual '
                          'swipe). Just press Home instead.',
                    ),
                    const _Step(
                      number: 2,
                      title: 'Lock the app in Recents',
                      body:
                          'Pull down on the Cute Bot card in Recents (or '
                          'long-press it) and tap the lock icon. This protects '
                          'against "clean all" — though not against swiping the '
                          'card away individually.',
                    ),
                    const _Step(
                      number: 3,
                      title: 'Allow autostart',
                      body:
                          'Settings → Apps → Cute Bot → turn on Autostart '
                          '(on some models: i Manager → App manager → Autostart '
                          'manager).',
                    ),
                    const _Step(
                      number: 4,
                      title: 'Allow high background power use',
                      body:
                          'Settings → Battery → Background power consumption '
                          'management → Cute Bot → allow high background power '
                          'consumption.',
                    ),
                    const SizedBox(height: CuteBotSpace.lg),
                    _batteryBlock(context),
                    if (!controller.companionLink.state.associated) ...[
                      const SizedBox(height: CuteBotSpace.xl),
                      _cdmReminder(context),
                    ],
                    const SizedBox(height: CuteBotSpace.xl),
                    NdButton.primary(
                      label: 'Done',
                      expand: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notificationAccessBlock(BuildContext context) {
    final nd = context.nd;
    final granted = controller.notificationAccessGranted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NdLabel(
          'The fix',
          color: granted ? nd.colors.textSecondary : CuteBotSignal.accent,
        ),
        const SizedBox(height: CuteBotSpace.sm),
        Text(
          'Allow Notification access',
          style: nd.typography.body,
        ),
        const SizedBox(height: CuteBotSpace.sm),
        Text(
          'Cute Bot needs Notification access to show phone alerts on '
          'the robot (LED blink + chirp for WhatsApp, calls, and other '
          'notifications). It also keeps the companion running: Android '
          'reconnects apps with this access after the phone kills '
          'background apps.',
          style: nd.typography.bodySm.copyWith(color: nd.colors.textSecondary),
        ),
        const SizedBox(height: CuteBotSpace.md),
        if (granted)
          const NdStatusText('[NOTIFICATION ACCESS ON]')
        else
          NdButton.primary(
            label: 'Open Notification access settings',
            expand: true,
            onPressed: controller.openNotificationAccessSettings,
          ),
      ],
    );
  }

  Widget _batteryBlock(BuildContext context) {
    final nd = context.nd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NdLabel('And one we can do from here'),
        const SizedBox(height: CuteBotSpace.sm),
        if (controller.batteryOptimizationExempt)
          const NdStatusText('[BATTERY OPTIMIZATION OFF]')
        else ...[
          Text(
            'Exempt Cute Bot from Android battery optimization '
            '(shows a system dialog).',
            style: nd.typography.body.copyWith(color: nd.colors.textSecondary),
          ),
          const SizedBox(height: CuteBotSpace.md),
          NdButton.secondary(
            label: 'Allow background',
            expand: true,
            onPressed: controller.requestBatteryExemption,
          ),
        ],
      ],
    );
  }

  Widget _cdmReminder(BuildContext context) {
    final nd = context.nd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NdLabel('Re-link the bot to Android'),
        const SizedBox(height: CuteBotSpace.sm),
        Text(
          'The bot is not linked to Android right now (the phone\'s '
          'cleaner can clear the link). Use "Link bot to Android" on '
          'the Companion page so Android wakes the companion whenever '
          'the bot comes into range.',
          style: nd.typography.body.copyWith(color: nd.colors.textSecondary),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
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
