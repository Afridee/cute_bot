// Step selection, skip-later, and re-entry for Companion setup.
// Pure facts — no plugins, no widget tree.

import 'package:cute_bot/companion/brain/brain_session.dart';
import 'package:cute_bot/companion/setup/companion_setup.dart';
import 'package:flutter_test/flutter_test.dart';

CompanionSetupFacts _facts({
  bool welcomeSeen = false,
  bool notificationsGranted = false,
  bool bleAuthorized = false,
  bool bluetoothOn = false,
  bool batteryUnrestricted = false,
  bool notificationAccessGranted = false,
  bool isAggressiveOem = false,
  bool oemKeepAliveAcknowledged = false,
  bool oemKeepAliveSkipped = false,
  bool cdmAssociated = false,
  bool cdmSkipped = false,
  bool brainReady = false,
  bool fakeBrain = false,
}) {
  return CompanionSetupFacts(
    welcomeSeen: welcomeSeen,
    notificationsGranted: notificationsGranted,
    bleAuthorized: bleAuthorized,
    bluetoothOn: bluetoothOn,
    batteryUnrestricted: batteryUnrestricted,
    notificationAccessGranted: notificationAccessGranted,
    isAggressiveOem: isAggressiveOem,
    oemKeepAliveAcknowledged: oemKeepAliveAcknowledged,
    oemKeepAliveSkipped: oemKeepAliveSkipped,
    cdmAssociated: cdmAssociated,
    cdmSkipped: cdmSkipped,
    brainReady: brainReady,
    fakeBrain: fakeBrain,
  );
}

/// Everything blocking is true; skip-later items skipped. Panel unlocks.
CompanionSetupFacts _unlocked({
  bool welcomeSeen = true,
  bool isAggressiveOem = false,
  bool oemKeepAliveSkipped = false,
  bool cdmSkipped = true,
  bool fakeBrain = true,
}) {
  return _facts(
    welcomeSeen: welcomeSeen,
    notificationsGranted: true,
    bleAuthorized: true,
    bluetoothOn: true,
    batteryUnrestricted: true,
    notificationAccessGranted: true,
    isAggressiveOem: isAggressiveOem,
    oemKeepAliveSkipped: oemKeepAliveSkipped,
    cdmSkipped: cdmSkipped,
    fakeBrain: fakeBrain,
    brainReady: !fakeBrain,
  );
}

void main() {
  group('resolveCompanionSetupStep', () {
    test('cold install starts on Welcome', () {
      expect(resolveCompanionSetupStep(_facts()), CompanionSetupStep.welcome);
    });

    test('API < 33 omits notifications and still starts on Welcome', () {
      expect(
        resolveCompanionSetupStep(_facts(notificationsGranted: true)),
        CompanionSetupStep.welcome,
      );
      expect(
        firstBlockingCompanionSetupStep(_facts(notificationsGranted: true)),
        CompanionSetupStep.bluetooth,
      );
    });

    test('after Welcome, first failed blocking step is notifications', () {
      expect(
        resolveCompanionSetupStep(_facts(welcomeSeen: true)),
        CompanionSetupStep.notifications,
      );
    });

    test('walks the blocking chain in order', () {
      var facts = _facts(welcomeSeen: true, notificationsGranted: true);
      expect(resolveCompanionSetupStep(facts), CompanionSetupStep.bluetooth);

      facts = _facts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
      );
      expect(resolveCompanionSetupStep(facts), CompanionSetupStep.bluetooth);

      facts = _facts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
        bluetoothOn: true,
      );
      expect(resolveCompanionSetupStep(facts), CompanionSetupStep.battery);

      facts = _facts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
        bluetoothOn: true,
        batteryUnrestricted: true,
      );
      expect(
        resolveCompanionSetupStep(facts),
        CompanionSetupStep.notificationAccess,
      );
    });

    test('vivo/iQOO get the autostart step; other OEMs skip it', () {
      final base = _facts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
        bluetoothOn: true,
        batteryUnrestricted: true,
        notificationAccessGranted: true,
      );
      expect(resolveCompanionSetupStep(base), CompanionSetupStep.cdmLink);
      expect(
        resolveCompanionSetupStep(
          _facts(
            welcomeSeen: true,
            notificationsGranted: true,
            bleAuthorized: true,
            bluetoothOn: true,
            batteryUnrestricted: true,
            notificationAccessGranted: true,
            isAggressiveOem: true,
          ),
        ),
        CompanionSetupStep.oemKeepAlive,
      );
    });

    test('OEM skip later does not re-block', () {
      expect(
        resolveCompanionSetupStep(
          _facts(
            welcomeSeen: true,
            notificationsGranted: true,
            bleAuthorized: true,
            bluetoothOn: true,
            batteryUnrestricted: true,
            notificationAccessGranted: true,
            isAggressiveOem: true,
            oemKeepAliveSkipped: true,
          ),
        ),
        CompanionSetupStep.cdmLink,
      );
      expect(
        resolveCompanionSetupStep(
          _facts(
            welcomeSeen: true,
            notificationsGranted: true,
            bleAuthorized: true,
            bluetoothOn: true,
            batteryUnrestricted: true,
            notificationAccessGranted: true,
            isAggressiveOem: true,
            oemKeepAliveAcknowledged: true,
          ),
        ),
        CompanionSetupStep.cdmLink,
      );
    });

    test('CDM skip later does not re-block', () {
      expect(
        resolveCompanionSetupStep(
          _facts(
            welcomeSeen: true,
            notificationsGranted: true,
            bleAuthorized: true,
            bluetoothOn: true,
            batteryUnrestricted: true,
            notificationAccessGranted: true,
            cdmSkipped: true,
          ),
        ),
        CompanionSetupStep.brain,
      );
      expect(
        resolveCompanionSetupStep(
          _facts(
            welcomeSeen: true,
            notificationsGranted: true,
            bleAuthorized: true,
            bluetoothOn: true,
            batteryUnrestricted: true,
            notificationAccessGranted: true,
            cdmAssociated: true,
          ),
        ),
        CompanionSetupStep.brain,
      );
    });

    test('FakeBrain omits the download wait', () {
      expect(resolveCompanionSetupStep(_unlocked()), CompanionSetupStep.done);
      expect(
        firstBlockingCompanionSetupStep(
          _facts(
            welcomeSeen: true,
            notificationsGranted: true,
            bleAuthorized: true,
            bluetoothOn: true,
            batteryUnrestricted: true,
            notificationAccessGranted: true,
            cdmSkipped: true,
            fakeBrain: true,
          ),
        ),
        CompanionSetupStep.done,
      );
    });

    test('real brain blocks until ready / thinking / responding', () {
      final waiting = _facts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
        bluetoothOn: true,
        batteryUnrestricted: true,
        notificationAccessGranted: true,
        cdmSkipped: true,
      );
      expect(resolveCompanionSetupStep(waiting), CompanionSetupStep.brain);
      expect(
        resolveCompanionSetupStep(_unlocked(fakeBrain: false)),
        CompanionSetupStep.done,
      );
    });

    test('re-entry after revoke lands on the first failed blocking step', () {
      final revokedBle = CompanionSetupFacts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: false,
        bluetoothOn: false,
        batteryUnrestricted: true,
        notificationAccessGranted: true,
        isAggressiveOem: true,
        oemKeepAliveAcknowledged: false,
        oemKeepAliveSkipped: true,
        cdmAssociated: true,
        cdmSkipped: false,
        brainReady: true,
        fakeBrain: false,
      );
      expect(resolveCompanionSetupStep(revokedBle), CompanionSetupStep.bluetooth);

      final revokedBattery = CompanionSetupFacts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
        bluetoothOn: true,
        batteryUnrestricted: false,
        notificationAccessGranted: true,
        isAggressiveOem: false,
        oemKeepAliveAcknowledged: false,
        oemKeepAliveSkipped: false,
        cdmAssociated: true,
        cdmSkipped: false,
        brainReady: true,
        fakeBrain: false,
      );
      expect(
        resolveCompanionSetupStep(revokedBattery),
        CompanionSetupStep.battery,
      );

      final revokedAccess = CompanionSetupFacts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
        bluetoothOn: true,
        batteryUnrestricted: true,
        notificationAccessGranted: false,
        isAggressiveOem: false,
        oemKeepAliveAcknowledged: false,
        oemKeepAliveSkipped: false,
        cdmSkipped: true,
        cdmAssociated: false,
        brainReady: true,
        fakeBrain: false,
      );
      expect(
        resolveCompanionSetupStep(revokedAccess),
        CompanionSetupStep.notificationAccess,
      );
    });

    test('skipped OEM stays skipped on re-entry', () {
      final facts = CompanionSetupFacts(
        welcomeSeen: true,
        notificationsGranted: true,
        bleAuthorized: true,
        bluetoothOn: true,
        batteryUnrestricted: true,
        notificationAccessGranted: true,
        isAggressiveOem: true,
        oemKeepAliveAcknowledged: false,
        oemKeepAliveSkipped: true,
        cdmAssociated: true,
        cdmSkipped: false,
        brainReady: true,
        fakeBrain: false,
      );
      expect(resolveCompanionSetupStep(facts), CompanionSetupStep.done);
    });

    test('Welcome is not shown again after it was seen', () {
      expect(
        resolveCompanionSetupStep(_facts(welcomeSeen: true)),
        CompanionSetupStep.notifications,
      );
    });
  });

  group('companionBrainIsReady', () {
    test('ready, thinking, and responding unlock; cold and warming do not', () {
      expect(companionBrainIsReady(BrainSessionState.ready), isTrue);
      expect(companionBrainIsReady(BrainSessionState.thinking), isTrue);
      expect(companionBrainIsReady(BrainSessionState.responding), isTrue);
      expect(companionBrainIsReady(BrainSessionState.cold), isFalse);
      expect(companionBrainIsReady(BrainSessionState.warming), isFalse);
    });
  });

  group('companionSetupTrail', () {
    test('omits OEM on non-vivo, brain on FakeBrain, and granted notifications',
        () {
      final trail = companionSetupTrail(_unlocked());
      expect(trail, isNot(contains(CompanionSetupStep.oemKeepAlive)));
      expect(trail, isNot(contains(CompanionSetupStep.brain)));
      expect(trail, isNot(contains(CompanionSetupStep.notifications)));
    });

    test('includes OEM on vivo and brain when the real model is used', () {
      final trail = companionSetupTrail(
        _unlocked(isAggressiveOem: true, fakeBrain: false),
      );
      expect(trail, contains(CompanionSetupStep.oemKeepAlive));
      expect(trail, contains(CompanionSetupStep.brain));
    });
  });
}
