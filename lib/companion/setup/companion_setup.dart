// Pure first-run / re-entry resolver for Companion setup.
//
// Completeness is derived from live checks + skip flags — there is no
// setupComplete flag, so a revoked permission lands the user on the first
// failed blocking step. See Docs/companion-setup.md.

import '../brain/brain_session.dart';

enum CompanionSetupStep {
  welcome,
  notifications,
  bluetooth,
  battery,
  notificationAccess,
  oemKeepAlive,
  cdmLink,
  brain,
  done,
}

/// Snapshot of everything [resolveCompanionSetupStep] needs. No I/O.
final class CompanionSetupFacts {
  const CompanionSetupFacts({
    required this.welcomeSeen,
    required this.notificationsGranted,
    required this.bleAuthorized,
    required this.bluetoothOn,
    required this.batteryUnrestricted,
    required this.notificationAccessGranted,
    required this.isAggressiveOem,
    required this.oemKeepAliveAcknowledged,
    required this.oemKeepAliveSkipped,
    required this.cdmAssociated,
    required this.cdmSkipped,
    required this.brainReady,
    required this.fakeBrain,
  });

  /// Welcome was dismissed once on this install.
  final bool welcomeSeen;

  /// POST_NOTIFICATIONS granted, or API < 33 (step omitted).
  final bool notificationsGranted;
  final bool bleAuthorized;
  final bool bluetoothOn;
  final bool batteryUnrestricted;
  final bool notificationAccessGranted;
  final bool isAggressiveOem;
  final bool oemKeepAliveAcknowledged;
  final bool oemKeepAliveSkipped;
  final bool cdmAssociated;
  final bool cdmSkipped;

  /// Model downloaded and loaded (`ready` / `thinking` / `responding`).
  final bool brainReady;

  /// `CUTEBOT_FAKE_BRAIN=true` — omit the download wait.
  final bool fakeBrain;

  bool get bluetoothReady => bleAuthorized && bluetoothOn;

  bool get oemKeepAliveDone =>
      !isAggressiveOem || oemKeepAliveAcknowledged || oemKeepAliveSkipped;

  bool get cdmDone => cdmAssociated || cdmSkipped;

  bool get brainDone => fakeBrain || brainReady;
}

/// First unsatisfied step, or [CompanionSetupStep.done].
///
/// Welcome is first-run only: skipped once [CompanionSetupFacts.welcomeSeen]
/// is true, so a later revoke lands on the failed blocking step.
CompanionSetupStep resolveCompanionSetupStep(CompanionSetupFacts facts) {
  final blocking = firstBlockingCompanionSetupStep(facts);
  if (blocking == CompanionSetupStep.done) return CompanionSetupStep.done;
  if (!facts.welcomeSeen) return CompanionSetupStep.welcome;
  return blocking;
}

/// Blocking / skip-later chain without Welcome. Used for re-entry tests and
/// to decide when the service is allowed to start (notifications + BLE).
CompanionSetupStep firstBlockingCompanionSetupStep(CompanionSetupFacts facts) {
  if (!facts.notificationsGranted) return CompanionSetupStep.notifications;
  if (!facts.bluetoothReady) return CompanionSetupStep.bluetooth;
  if (!facts.batteryUnrestricted) return CompanionSetupStep.battery;
  if (!facts.notificationAccessGranted) {
    return CompanionSetupStep.notificationAccess;
  }
  if (!facts.oemKeepAliveDone) return CompanionSetupStep.oemKeepAlive;
  if (!facts.cdmDone) return CompanionSetupStep.cdmLink;
  if (!facts.brainDone) return CompanionSetupStep.brain;
  return CompanionSetupStep.done;
}

bool companionBrainIsReady(BrainSessionState state) =>
    state == BrainSessionState.ready ||
    state == BrainSessionState.thinking ||
    state == BrainSessionState.responding;

/// Ordered steps the wizard can show, given OEM / FakeBrain / API level.
List<CompanionSetupStep> companionSetupTrail(CompanionSetupFacts facts) {
  return [
    CompanionSetupStep.welcome,
    if (!facts.notificationsGranted) CompanionSetupStep.notifications,
    CompanionSetupStep.bluetooth,
    CompanionSetupStep.battery,
    CompanionSetupStep.notificationAccess,
    if (facts.isAggressiveOem) CompanionSetupStep.oemKeepAlive,
    CompanionSetupStep.cdmLink,
    if (!facts.fakeBrain) CompanionSetupStep.brain,
  ];
}
