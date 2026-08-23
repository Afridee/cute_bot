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
}
