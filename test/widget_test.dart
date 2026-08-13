import 'package:cute_bot/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mode select screen shows both modes', (tester) async {
    await tester.pumpWidget(const CuteBotApp());
    expect(find.text('Bot Simulator'), findsOneWidget);
    expect(find.text('Companion'), findsOneWidget);
  });
}
