import 'package:cute_bot/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mode select screen shows both modes', (tester) async {
    await tester.pumpWidget(const CuteBotApp());
    expect(find.text('COMPANION'), findsOneWidget);
    expect(find.text('BOT SIMULATOR'), findsOneWidget);
    expect(find.text('CUTE BOT'), findsOneWidget);
  });
}
