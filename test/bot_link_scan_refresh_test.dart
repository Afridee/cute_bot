import 'package:cute_bot/companion/bot_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 8, 23, 16, 0, 0);

  test('does not refresh unless we are scanning', () {
    expect(
      shouldRefreshStaleScan(
        state: BotLinkState.ready,
        scanningSince: now.subtract(kScanStaleAfter),
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldRefreshStaleScan(
        state: BotLinkState.scanning,
        scanningSince: null,
        now: now,
      ),
      isFalse,
    );
  });

  test('refreshes only after the stale window', () {
    expect(
      shouldRefreshStaleScan(
        state: BotLinkState.scanning,
        scanningSince: now.subtract(const Duration(seconds: 24)),
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldRefreshStaleScan(
        state: BotLinkState.scanning,
        scanningSince: now.subtract(kScanStaleAfter),
        now: now,
      ),
      isTrue,
    );
  });

  test('does not adopt scanning once a connect is in flight', () {
    expect(shouldAdoptScanningState(BotLinkState.scanning), isTrue);
    expect(shouldAdoptScanningState(BotLinkState.reconnectWait), isTrue);
    expect(shouldAdoptScanningState(BotLinkState.idle), isTrue);
    expect(shouldAdoptScanningState(BotLinkState.connecting), isFalse);
    expect(shouldAdoptScanningState(BotLinkState.configuring), isFalse);
    expect(shouldAdoptScanningState(BotLinkState.ready), isFalse);
  });

  group('notify liveness', () {
    test('does nothing unless the link is ready', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.connecting,
          now: now,
          lastInboundAt: null,
          probeSentAt: null,
        ),
        NotifyLivenessAction.none,
      );
    });

    test('waits out the grace period after becoming ready', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.ready,
          now: now,
          lastInboundAt: null,
          probeSentAt: null,
          readySince: now,
        ),
        NotifyLivenessAction.none,
      );
    });

    test('probes once when ready with no inbound', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.ready,
          now: now,
          lastInboundAt: null,
          probeSentAt: null,
          readySince: now.subtract(kNotifyProbeGrace),
        ),
        NotifyLivenessAction.probe,
      );
    });

    test('does not probe while inbound is still fresh', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.ready,
          now: now,
          lastInboundAt: now.subtract(const Duration(seconds: 9)),
          probeSentAt: null,
          readySince: now.subtract(const Duration(minutes: 5)),
        ),
        NotifyLivenessAction.none,
      );
    });

    test('probes again after inbound has gone quiet', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.ready,
          now: now,
          lastInboundAt: now.subtract(kNotifySilenceBeforeProbe),
          probeSentAt: null,
          readySince: now.subtract(const Duration(minutes: 5)),
        ),
        NotifyLivenessAction.probe,
      );
    });

    test('reconnects if a silence probe stays unanswered', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.ready,
          now: now,
          lastInboundAt: now.subtract(kNotifySilenceBeforeProbe),
          probeSentAt: now.subtract(kNotifyProbeTimeout),
          readySince: now.subtract(const Duration(minutes: 5)),
        ),
        NotifyLivenessAction.reconnect,
      );
    });

    test('reconnects if the probe stays silent', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.ready,
          now: now,
          lastInboundAt: null,
          probeSentAt: now.subtract(kNotifyProbeTimeout),
          readySince: now.subtract(kNotifyProbeGrace),
        ),
        NotifyLivenessAction.reconnect,
      );
    });

    test('waits out the probe window before reconnecting', () {
      expect(
        notifyLivenessAction(
          state: BotLinkState.ready,
          now: now,
          lastInboundAt: null,
          probeSentAt: now.subtract(const Duration(milliseconds: 500)),
          readySince: now.subtract(kNotifyProbeGrace),
        ),
        NotifyLivenessAction.none,
      );
    });
  });

  group('scan dwell winner', () {
    test('returns null when there are no candidates', () {
      expect(pickScanWinner({}), isNull);
    });

    test('prefers a live RSSI over a cached ghost', () {
      expect(
        pickScanWinner({
          'ghost': -84,
          'live': -41,
        }),
        'live',
      );
    });

    test('falls back to the loudest ghost if nothing is live', () {
      expect(
        pickScanWinner({
          'far': -92,
          'cached': -84,
        }),
        'cached',
      );
    });
  });
}
