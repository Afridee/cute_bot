import 'package:cute_bot/shared/timer_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timer_display', () {
    test('format and parse round-trip', () {
      const d = Duration(hours: 1, minutes: 2, seconds: 3);
      expect(formatRemainingHhMmSs(d), '01:02:03');
      expect(parseHhMmSs('01:02:03'), d);
      expect(isTimerDisplayText('00:01:00'), isTrue);
      expect(isTimerDisplayText('thinking'), isFalse);
    });
  });
}
