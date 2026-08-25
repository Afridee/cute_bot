import 'package:cute_bot/bot_simulator/advertise_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('advertiseRetryDelay', () {
    test('first try after disconnect waits the resume beat', () {
      expect(advertiseRetryDelay(0), kAdvertiseResumeDelay);
    });

    test('doubles each miss and caps at the max backoff', () {
      expect(advertiseRetryDelay(1), const Duration(milliseconds: 800));
      expect(advertiseRetryDelay(2), const Duration(milliseconds: 1600));
      expect(advertiseRetryDelay(3), const Duration(milliseconds: 3200));
      expect(advertiseRetryDelay(4), const Duration(milliseconds: 6400));
      expect(advertiseRetryDelay(5), kAdvertiseMaxBackoff);
      expect(advertiseRetryDelay(20), kAdvertiseMaxBackoff);
    });
  });

  group('advertiseRecoveryAction', () {
    test('retries advertise on the first attempts', () {
      expect(advertiseRecoveryAction(0), AdvertiseRecoveryAction.retryAdvertise);
      expect(advertiseRecoveryAction(1), AdvertiseRecoveryAction.retryAdvertise);
      expect(advertiseRecoveryAction(2), AdvertiseRecoveryAction.retryAdvertise);
    });

    test('republishes GATT on every Nth consecutive failure', () {
      expect(
        advertiseRecoveryAction(kAdvertiseFailuresBeforeRepublish),
        AdvertiseRecoveryAction.republishServices,
      );
      expect(advertiseRecoveryAction(4), AdvertiseRecoveryAction.retryAdvertise);
      expect(
        advertiseRecoveryAction(kAdvertiseFailuresBeforeRepublish * 2),
        AdvertiseRecoveryAction.republishServices,
      );
    });
  });

  group('unconfirmed central handshake', () {
    final now = DateTime(2026, 8, 25, 16, 0, 0);

    test('keeps a central that has written or subscribed', () {
      expect(
        shouldDropUnconfirmedCentral(
          now: now,
          connectedAt: now.subtract(kUnconfirmedCentralTimeout),
          confirmed: true,
        ),
        isFalse,
      );
    });

    test('waits out the handshake window', () {
      expect(
        shouldDropUnconfirmedCentral(
          now: now,
          connectedAt: now.subtract(const Duration(seconds: 7)),
          confirmed: false,
        ),
        isFalse,
      );
    });

    test('drops a CDM ghost that never handshakes', () {
      expect(
        shouldDropUnconfirmedCentral(
          now: now,
          connectedAt: now.subtract(kUnconfirmedCentralTimeout),
          confirmed: false,
        ),
        isTrue,
      );
    });
  });
}
