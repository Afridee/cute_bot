import 'package:cute_bot/companion/brain/fast_intent.dart';
import 'package:cute_bot/companion/brain/fast_intent_enroll.dart';
import 'package:cute_bot/companion/brain/fast_intent_overlay.dart';
import 'package:cute_bot/companion/brain/transcript.dart';
import 'package:cute_bot/companion/service/fast_intent_store.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceEnrollSample _pauseTakes() => const VoiceEnrollSample(
      prompt: 'Pause the timer',
      intent: FastIntentId.pauseTimer,
      transcripts: [
        'WAS THE TEMPER',
        'pose the tamper',
        'pros the tamper bzz',
      ],
    );

void main() {
  group('FastIntentOverlay JSON', () {
    test('round-trips phrases and slots', () {
      const overlay = FastIntentOverlay(intents: {
        FastIntentId.pauseTimer: FastIntentAliases(
          phrases: ['was the temper', 'pose the tamper'],
          verb: ['pose', 'pros'],
          noun: ['temper', 'tamper'],
        ),
      });
      final decoded = FastIntentOverlay.decode(overlay.encode());
      expect(decoded, isNotNull);
      final pause = decoded!.of(FastIntentId.pauseTimer);
      expect(pause.phrases, ['was the temper', 'pose the tamper']);
      expect(pause.verb, ['pose', 'pros']);
      expect(pause.noun, ['temper', 'tamper']);
      expect(decoded.of(FastIntentId.cancelTimer).isEmpty, isTrue);
    });

    test('missing or corrupt JSON is null', () {
      expect(FastIntentOverlay.decode(null), isNull);
      expect(FastIntentOverlay.decode(''), isNull);
      expect(FastIntentOverlay.decode('{'), isNull);
      expect(FastIntentOverlay.decode('{"version":2,"intents":{}}'), isNull);
    });
  });

  group('aligner', () {
    test('three pause takes → phrases, pose/pros verbs, temper/tamper nouns',
        () {
      final overlay = buildFastIntentOverlay([_pauseTakes()]);
      final pause = overlay.of(FastIntentId.pauseTimer);
      expect(
        pause.phrases,
        containsAll(['was the temper', 'pose the tamper', 'pros the tamper']),
      );
      expect(pause.verb, containsAll(['pose', 'pros']));
      expect(pause.verb, isNot(contains('was')));
      expect(pause.noun, containsAll(['temper', 'tamper']));
    });

    test('trailing unaligned junk is stripped from the phrase', () {
      final overlay = buildFastIntentOverlay([_pauseTakes()]);
      expect(
        overlay.of(FastIntentId.pauseTimer).phrases,
        contains('pros the tamper'),
      );
      expect(
        overlay.of(FastIntentId.pauseTimer).phrases,
        isNot(contains('pros the tamper bzz')),
      );
    });

    test('cancel substitutions do not land in pause slots', () {
      final overlay = buildFastIntentOverlay([
        _pauseTakes(),
        const VoiceEnrollSample(
          prompt: 'Cancel the timer',
          intent: FastIntentId.cancelTimer,
          transcripts: [
            'kanzel the timer',
            'kanzel the timer',
            'kanzel the timer',
          ],
        ),
      ]);
      expect(overlay.of(FastIntentId.pauseTimer).verb, isNot(contains('kanzel')));
      expect(overlay.of(FastIntentId.pauseTimer).verb, isNot(contains('cancel')));
      expect(overlay.of(FastIntentId.cancelTimer).verb, contains('kanzel'));
    });

    test('start the timer enrolls resume_timer, not set_timer', () {
      final overlay = buildFastIntentOverlay([
        const VoiceEnrollSample(
          prompt: 'Start the timer',
          intent: FastIntentId.resumeTimer,
          transcripts: [
            'start the diamer',
            'start the diamer',
            'start the dimer',
          ],
        ),
      ]);
      expect(overlay.of(FastIntentId.resumeTimer).phrases, isNotEmpty);
      expect(overlay.of(FastIntentId.resumeTimer).noun, contains('diamer'));
      expect(overlay.of(FastIntentId.setTimer).isEmpty, isTrue);
    });
  });

  group('matchText overlay', () {
    late FastIntentOverlay overlay;

    setUp(() {
      overlay = buildFastIntentOverlay([_pauseTakes()]);
    });

    test('WAS THE TEMPER BZZ pauses via phrase contain', () {
      final hit = matchText('WAS THE TEMPER BZZ', overlay);
      expect(hit, isNotNull);
      expect(hit!.calls.single.name, 'pause_timer');
    });

    test('I was the one who set the timer is not pause', () {
      final hit = matchText('I was the one who set the timer', overlay);
      expect(hit?.calls.single.name, isNot('pause_timer'));
    });

    test('pose the temper pauses via slot product', () {
      expect(matchText('pose the temper', overlay)!.calls.single.name,
          'pause_timer');
    });

    test('default pause the timer still hits with empty overlay', () {
      expect(matchText('pause the timer')!.calls.single.name, 'pause_timer');
      expect(
        matchText('pause the timer', const FastIntentOverlay())!
            .calls
            .single
            .name,
        'pause_timer',
      );
    });

    test('set-timer overlay phrase without a duration is a miss', () {
      const setOverlay = FastIntentOverlay(intents: {
        FastIntentId.setTimer: FastIntentAliases(
          phrases: ['set the diamer'],
        ),
      });
      expect(matchText('set the diamer', setOverlay), isNull);
      expect(
        matchText('set the diamer for twenty seconds', setOverlay)!
            .calls
            .single
            .name,
        'set_timer',
      );
    });
  });

  group('FastIntentStore', () {
    test('save then load round-trips on KeyValueStore', () async {
      final kv = InMemoryKeyValueStore();
      final store = FastIntentStore(kv);
      await store.load();
      expect(store.overlay, isNull);

      final overlay = buildFastIntentOverlay([_pauseTakes()]);
      await store.save(overlay);
      expect(kv.values[FastIntentStore.storageKey], isNotNull);

      final again = FastIntentStore(kv);
      await again.load();
      expect(again.hasOverlay, isTrue);
      expect(
        again.overlay!.of(FastIntentId.pauseTimer).phrases,
        contains('was the temper'),
      );
    });
  });
}
