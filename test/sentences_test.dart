import 'package:cute_bot/companion/voice/sentences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('takeSentences', () {
    test('holds a fragment until a terminator', () {
      final first = takeSentences('Hello there');
      expect(first.$1, isEmpty);
      expect(first.$2, 'Hello there');
    });

    test('cuts on period plus space', () {
      final got = takeSentences('Hello there. How are you? Almost');
      expect(got.$1, ['Hello there.', 'How are you?']);
      expect(got.$2, 'Almost');
    });

    test('flush takes the tail', () {
      final got = takeSentences('Almost done', flush: true);
      expect(got.$1, ['Almost done']);
      expect(got.$2, isEmpty);
    });

    test('force-splits a long unpunctuated ramble', () {
      final ramble = 'word ' * 40;
      final got = takeSentences(ramble);
      expect(got.$1, isNotEmpty);
      expect(got.$1.first.length, lessThanOrEqualTo(kForceSplitChars));
      expect(got.$2.length, lessThan(ramble.length));
    });

    test('empty flush is a no-op', () {
      final got = takeSentences('   ', flush: true);
      expect(got.$1, isEmpty);
    });
  });
}
