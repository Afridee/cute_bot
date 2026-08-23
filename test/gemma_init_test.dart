import 'package:cute_bot/companion/brain/gemma_init.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveGemmaModelUrl', () {
    test('empty override keeps the Hub default', () {
      expect(resolveGemmaModelUrl(''), kGemma4E2BHubUrl);
      expect(resolveGemmaModelUrl('   '), kGemma4E2BHubUrl);
    });

    test('trims a CDN override', () {
      const cdn = 'https://models.example.com/gemma-4-E2B-it.litertlm';
      expect(resolveGemmaModelUrl('  $cdn  '), cdn);
    });
  });

  group('isHuggingFaceModelUrl', () {
    test('matches Hub hosts only', () {
      expect(isHuggingFaceModelUrl(kGemma4E2BHubUrl), isTrue);
      expect(
        isHuggingFaceModelUrl(
          'https://cas-bridge.xethub.hf.co/xet/litert-community/file',
        ),
        isFalse,
      );
      expect(
        isHuggingFaceModelUrl(
          'https://pub-example.r2.dev/gemma-4-E2B-it.litertlm',
        ),
        isFalse,
      );
    });
  });

  test('downloadTokenForModelUrl skips Bearer on a CDN URL', () {
    expect(
      downloadTokenForModelUrl(
        'https://pub-example.r2.dev/gemma-4-E2B-it.litertlm',
      ),
      isNull,
    );
  });
}
