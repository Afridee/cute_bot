import 'package:cute_bot/companion/brain/fast_intent.dart';
import 'package:cute_bot/companion/brain/fast_intent_overlay.dart';
import 'package:cute_bot/companion/expressions.dart';
import 'package:flutter_test/flutter_test.dart';

/// `express:happy` / `set_timer` / `MISS` — the compact shape the mood tables
/// below assert against.
String route(String text, [FastIntentOverlay? overlay]) {
  final hit = matchText(text, overlay);
  if (hit == null) return 'MISS';
  final call = hit.calls.first;
  if (call.name != 'express') return call.name;
  return 'express:${call.arguments['mood']}';
}

String? routeReason(String text, [FastIntentOverlay? overlay]) =>
    matchText(text, overlay)?.reason;

/// One `express(mood)` with the expected route-log reason.
void expectMood(String text, String mood, String reasonTag) {
  expect(route(text), 'express:$mood', reason: 'utterance: "$text"');
  expect(routeReason(text), reasonTag, reason: 'utterance: "$text"');
}

void expectMiss(String text) {
  expect(route(text), 'MISS',
      reason: 'utterance: "$text" should reach the LLM');
}

/// Runs a `(utterance, mood, reason)` table as one test each.
void moodTable(List<(String, String, String)> cases) {
  for (final (text, mood, reasonTag) in cases) {
    test('"$text" → $mood', () => expectMood(text, mood, reasonTag));
  }
}

void missTable(List<String> cases) {
  for (final text in cases) {
    test('"$text" → LLM', () => expectMiss(text));
  }
}

void main() {
  // -------------------------------------------------------------------------
  // Tool intents. Precision matters most here: these must not regress when
  // the mood vocabulary grows.
  // -------------------------------------------------------------------------
  group('set_timer', () {
    test('minutes plus label', () {
      final hit = matchText('set a timer for three minutes, tea');
      expect(hit, isNotNull);
      final call = hit!.calls.single;
      expect(call.name, 'set_timer');
      expect(call.arguments['minutes'], 3);
      expect(call.arguments['label'], 'tea');
      expect(hit.reason, 'set-timer');
    });

    test('sub-minute durations use seconds', () {
      final call = matchText('set a timer for 20 seconds')!.calls.single;
      expect(call.name, 'set_timer');
      expect(call.arguments['seconds'], 20);
      expect(call.arguments.containsKey('minutes'), isFalse);
    });

    test('noun-first phrasing',
        () => expect(route('20 second timer'), 'set_timer'));
    test('half an hour',
        () => expect(route('half an hour timer'), 'set_timer'));
    test('a duration beats resume', () =>
        expect(route('start the timer for 5 minutes'), 'set_timer'));

    test('no duration is not a set', () => expectMiss('can you set a timer'));
    test('bare duration is chatter', () => expectMiss('in 20 seconds'));
  });

  group('set_timer slots', () {
    test('digits and a label after a comma', () {
      final call = matchText('set a timer for 5 minutes, steep')!.calls.single;
      expect(call.arguments['minutes'], 5);
      expect(call.arguments['label'], 'steep');
    });

    test('bare number after for', () {
      final call = matchText('set a timer for 3, tea')!.calls.single;
      expect(call.arguments['minutes'], 3);
      expect(call.arguments['label'], 'tea');
    });

    test('an hour becomes 60 minutes', () {
      final call = matchText('set a timer for an hour')!.calls.single;
      expect(call.arguments['minutes'], 60);
      expect(call.arguments['label'], 'timer');
    });

    test('over 180 minutes is a miss', () {
      expect(matchText('set a timer for four hours'), isNull);
    });

    test('remind me in ten minutes', () {
      expect(matchText('remind me in ten minutes')!.calls.single.arguments['minutes'], 10);
    });

    test('an hour and a half becomes 90', () {
      final call =
          matchText('set a timer for an hour and a half, bread')!.calls.single;
      expect(call.arguments['minutes'], 90);
      expect(call.arguments['label'], 'bread');
    });

    test('ASR near-miss diamer still sets seconds', () {
      final call =
          matchText('START THE DIAMER FOR TWENTY SECONDS')!.calls.single;
      expect(call.arguments['seconds'], 20);
    });

    test('ASR near-miss tymer with duration', () {
      expect(
        matchText('start the tymer for five minutes')!.calls.single.arguments,
        {'minutes': 5, 'label': 'timer'},
      );
    });

    test('near-miss timer without a duration is still a miss', () {
      expect(matchText('start the diamer'), isNull);
    });

    test('1 minute 20 seconds is mixed', () {
      final call =
          matchText('set a timer for 1 minute 20 seconds, tea')!.calls.single;
      expect(call.arguments['minutes'], 1);
      expect(call.arguments['seconds'], 20);
      expect(call.arguments['label'], 'tea');
    });
  });

  group('timer control', () {
    test('cancel', () {
      expect(route('cancel the timer'), 'cancel_timer');
      expect(routeReason('cancel the timer'), 'cancel-timer');
    });
    test('stop is a cancel',
        () => expect(route('stop the timer'), 'cancel_timer'));
    test('turn off', () => expect(route('turn off the timer'), 'cancel_timer'));
    test('pause', () => expect(route('pause the timer'), 'pause_timer'));
    test('resume', () => expect(route('resume the timer'), 'resume_timer'));
    test('start without a duration resumes',
        () => expect(route('start the timer'), 'resume_timer'));
    test('timer fire', () =>
        expectMood("A timer just finished: 'tea'.", 'alarm', 'timer-fire'));
    test('negation blocks the whole matcher',
        () => expectMiss("don't cancel the timer"));

    test('discourse prefixes do not become cancel labels', () {
      for (final utterance in [
        'You know what, cancel the timer.',
        "I'll cancel the timer",
        'Uh, cancel the timer',
      ]) {
        final hit = matchText(utterance);
        expect(hit!.reason, 'cancel-timer', reason: utterance);
        expect(hit.calls.single.transcriptLine, 'cancel_timer()');
        expect(hit.calls.single.arguments.containsKey('label'), isFalse);
      }
    });

    test('ASR canseled the timer is cancel, not a label', () {
      final hit = matchText('CANSELED THE TIMER');
      expect(hit!.reason, 'cancel-timer');
      expect(hit.calls.single.transcriptLine, 'cancel_timer()');
    });

    test('CANSELED THE DIAMOND is cancel, not resume of label CANSELED', () {
      const overlay = FastIntentOverlay(intents: {
        FastIntentId.resumeTimer: FastIntentAliases(
          phrases: ['resumed the diamond', 'the diamond'],
          verb: ['resumed'],
          noun: ['diamond'],
        ),
      });
      final cancel = matchText('CANSELED THE DIAMOND', overlay);
      expect(cancel!.reason, 'cancel-timer');
      expect(cancel.calls.single.transcriptLine, 'cancel_timer()');
    });

    test('WAS THE DIAMOND pauses via was-cue × shared noun', () {
      const overlay = FastIntentOverlay(intents: {
        FastIntentId.pauseTimer: FastIntentAliases(
          phrases: ['was the temper'],
          noun: ['temper'],
        ),
        FastIntentId.resumeTimer: FastIntentAliases(
          phrases: ['resumed the diamond', 'the diamond'],
          verb: ['resumed'],
          noun: ['diamond'],
        ),
      });
      final hit = matchText('WAS THE DIAMOND', overlay);
      expect(hit!.reason, 'pause-timer');
      expect(hit.calls.single.transcriptLine, 'pause_timer()');
    });
  });

  group('battery', () {
    test('asking',
        () => expect(route('how much battery do you have?'), 'get_battery'));
    test('charged', () => expect(route('are you charged?'), 'get_battery'));

    test('percent → mood', () {
      expect(moodFromBatteryPercent(5).name, 'low_battery');
      expect(moodFromBatteryPercent(19).name, 'low_battery');
      expect(moodFromBatteryPercent(25).name, 'sleepy');
      expect(moodFromBatteryPercent(80).name, 'yes');
      expect(moodFromBatteryPercent(null).name, 'confused');
      expect(moodFromBatteryPercent('80').name, 'confused');
    });
  });

  group('overlay is additive', () {
    const overlay = FastIntentOverlay(intents: {
      FastIntentId.pauseTimer: FastIntentAliases(
        phrases: ['was the temper'],
        noun: ['temper'],
      ),
    });

    test('enrolled phrase', () =>
        expect(route('was the temper', overlay), 'pause_timer'));
    test('enrolled noun with a default verb', () =>
        expect(route('pause the temper', overlay), 'pause_timer'));
    test('defaults still win', () =>
        expect(route('cancel the timer', overlay), 'cancel_timer'));
    test('no overlay is unchanged', () =>
        expect(route('was the temper'), 'MISS'));

    test('enrolled pause phrase hits; unrelated was-the does not', () {
      const overlay = FastIntentOverlay(intents: {
        FastIntentId.pauseTimer: FastIntentAliases(
          phrases: ['was the temper'],
          verb: ['pose', 'pros'],
          noun: ['temper', 'tamper'],
        ),
      });
      expect(matchText('WAS THE TEMPER BZZ', overlay)!.reason, 'pause-timer');
      expect(matchText('I was the one who set the timer', overlay)?.reason,
          isNot('pause-timer'));
    });
  });

  group('moodFromBatteryPercent', () {
    test('bands match the persona', () {
      expect(moodFromBatteryPercent(null), BotMood.confused);
      expect(moodFromBatteryPercent(12), BotMood.low_battery);
      expect(moodFromBatteryPercent(28), BotMood.sleepy);
      expect(moodFromBatteryPercent(82), BotMood.yes);
    });
  });

  // -------------------------------------------------------------------------
  // Mood clusters.
  // -------------------------------------------------------------------------
  group('praise', () {
    moodTable(const [
      ('You are a good boy.', 'happy', 'praise'),
      ('good girl', 'happy', 'praise'),
      ('what a good boy', 'happy', 'praise'),
      ("who's a good little robot", 'happy', 'praise'),
      ('good bot', 'happy', 'praise'),
      ('nice bot', 'happy', 'praise'),
      ('sweet girl', 'happy', 'praise'),
      ('clever bud', 'happy', 'praise'),
      ("you're so clever", 'happy', 'praise'),
      ('you are amazing', 'happy', 'praise'),
      ("you're the best", 'happy', 'praise'),
      ('best bot ever', 'happy', 'praise'),
      ('good helper', 'happy', 'praise'),
      ('i like you', 'happy', 'praise'),
      ('thank you', 'happy', 'thanks'),
      ('thanks buddy', 'happy', 'thanks'),
      ('appreciate it', 'happy', 'thanks'),
      ('good job', 'proud', 'well-done'),
      ('well done little guy', 'proud', 'well-done'),
      ('nice work', 'proud', 'well-done'),
      ('way to go', 'proud', 'well-done'),
      ("i'm proud of you", 'proud', 'well-done'),
      ('you nailed it', 'proud', 'well-done'),
      ('bravo', 'proud', 'well-done'),
    ]);

    // Praise needs an address; bare adjectives belong to the LLM.
    missTable(const [
      'good friend',
      "that's a good thing",
      'he is a good man',
      'I had a great day',
    ]);
  });

  group('affection', () {
    moodTable(const [
      ('i love you', 'love', 'affection'),
      ('love you little guy', 'love', 'affection'),
      ('i missed you', 'love', 'affection'),
      ("you're cute", 'love', 'affection'),
      ('you are so adorable', 'love', 'affection'),
      ("you're sweet", 'love', 'affection'),
      ('cutie', 'love', 'affection'),
      ('my little guy', 'love', 'affection'),
      ('come here', 'love', 'affection'),
      ('give me a hug', 'love', 'affection'),
      ('snuggle time', 'love', 'affection'),
      ('kisses', 'love', 'affection'),
      ('you make me happy', 'love', 'affection'),
    ]);

    missTable(const [
      "i don't love you",
      'I love pizza and cold weather',
      'kiss the cook',
    ]);
  });

  group('comfort', () {
    moodTable(const [
      ("i'm sad", 'sad', 'comfort'),
      ('i am sad', 'sad', 'comfort'),
      ("i'm so lonely", 'sad', 'comfort'),
      ("i'm stressed", 'sad', 'comfort'),
      ('feeling down', 'sad', 'comfort'),
      ('bad day', 'sad', 'comfort'),
      ('i had a rough week', 'sad', 'comfort'),
      ('i need a hug', 'sad', 'comfort'),
      ('worst day ever', 'sad', 'comfort'),
      ('cheer me up', 'sad', 'comfort'),
    ]);

    // Comfort stays narrow on purpose — hedged emotional talk deserves the
    // model's turn, not a blue LED.
    missTable(const [
      'I am feeling a bit sad today',
      'today was interesting',
      "i'm fine",
    ]);
  });

  group('sleepy', () {
    moodTable(const [
      ("i'm tired", 'sleepy', 'sleepy'),
      ('i am so exhausted', 'sleepy', 'sleepy'),
      ('i need a nap', 'sleepy', 'sleepy'),
      ('yawning', 'sleepy', 'sleepy'),
      ('are you sleepy', 'sleepy', 'sleepy'),
      ('time for bed', 'sleepy', 'wind-down'),
      ('bedtime', 'sleepy', 'wind-down'),
      ('go to sleep', 'sleepy', 'wind-down'),
      ('sweet dreams', 'sleepy', 'wind-down'),
      ('night night', 'sleepy', 'wind-down'),
      ('good night', 'sleepy', 'good-night'),
    ]);

    missTable(const [
      "i'm tired of this nonsense",
      "I'm not tired",
    ]);
  });

  group('farewell', () {
    moodTable(const [
      ('bye', 'sad', 'goodbye'),
      ('goodbye little guy', 'sad', 'goodbye'),
      ('see you later', 'sad', 'goodbye'),
      ('gotta go', 'sad', 'goodbye'),
      ('take care', 'sad', 'goodbye'),
      ("i'm heading out", 'sad', 'goodbye'),
      ('talk to you later', 'sad', 'goodbye'),
      ('until tomorrow', 'sad', 'goodbye'),
    ]);

    missTable(const ['take care of the dishes']);
  });

  group('greeting and ping', () {
    moodTable(const [
      ('hey', 'curious', 'greeting'),
      ('hi there', 'curious', 'greeting'),
      ('hello bot', 'curious', 'greeting'),
      ('hey little guy, you awake?', 'curious', 'greeting'),
      ('are you there', 'curious', 'greeting'),
      ('can you hear me', 'curious', 'greeting'),
      ("what's up", 'curious', 'greeting'),
      ('what are you doing', 'curious', 'greeting'),
      ('are you ok', 'curious', 'greeting'),
      ('how are you', 'curious', 'greeting'),
      ('good morning', 'curious', 'greeting'),
      ('wake up', 'curious', 'greeting'),
      ('look at me', 'curious', 'greeting'),
    ]);

    missTable(const [
      "what's the plan for tomorrow",
      'the weather is nice today',
    ]);
  });

  group('play', () {
    moodTable(const [
      ('wanna play', 'playful', 'play'),
      ("let's play", 'playful', 'play'),
      ('peekaboo', 'playful', 'play'),
      ('tickle tickle', 'playful', 'play'),
      ('do it again', 'playful', 'play'),
      ('again', 'playful', 'play'),
      ('one more time', 'playful', 'play'),
      ('high five', 'playful', 'play'),
      ("you're so silly", 'playful', 'play'),
      ('silly bot', 'playful', 'play'),
      ('chase me', 'playful', 'play'),
      ("let's go", 'playful', 'play'),
      ("tag you're it", 'playful', 'play'),
      ('do a trick', 'playful', 'play'),
    ]);

    missTable(const [
      'tag along',
      'I went to the store again yesterday',
    ]);
  });

  group('delighted', () {
    moodTable(const [
      ('do a little dance', 'delighted', 'dance'),
      ('wiggle for me', 'delighted', 'dance'),
      ('yay', 'delighted', 'celebrate'),
      ('woohoo', 'delighted', 'celebrate'),
      ('hooray', 'delighted', 'celebrate'),
      ('we did it', 'delighted', 'celebrate'),
      ("i'm so excited", 'delighted', 'celebrate'),
      ('congratulations', 'delighted', 'celebrate'),
      ('i got the job', 'delighted', 'celebrate'),
    ]);

    missTable(const ['boogie time']);
  });

  group('scold', () {
    moodTable(const [
      ('bad bot', 'sad', 'scold'),
      ('bad robot', 'sad', 'scold'),
      ('stupid robot', 'sad', 'scold'),
      ('naughty bot', 'sad', 'scold'),
      ("you're being bad", 'sad', 'scold'),
      ('useless machine', 'sad', 'scold'),
      ('go away', 'sad', 'scold'),
      ('leave me alone', 'sad', 'scold'),
    ]);

    // Not aimed at the bot.
    missTable(const [
      'my boss is annoying',
      'the weather is bad today',
    ]);
  });

  group('annoyed', () {
    moodTable(const [
      ('ugh', 'annoyed', 'annoyed'),
      ('ugh seriously', 'annoyed', 'annoyed'),
      ('enough already', 'annoyed', 'annoyed'),
      ("that's enough", 'annoyed', 'annoyed'),
      ('knock it off', 'annoyed', 'annoyed'),
      ('cut it out', 'annoyed', 'annoyed'),
      ('so annoying', 'annoyed', 'annoyed'),
      ('not again', 'annoyed', 'annoyed'),
      ('oh come on', 'annoyed', 'annoyed'),
    ]);

    // The two things annoyed must never steal, plus a false friend.
    missTable(const [
      'stop beeping',
      "that's enough sugar",
    ]);
    test('stop the timer stays a cancel',
        () => expect(route('stop the timer'), 'cancel_timer'));
  });

  group('quiet', () {
    moodTable(const [
      ('be quiet', 'yes', 'quiet'),
      ('shhh', 'yes', 'quiet'),
      ('hush now', 'yes', 'quiet'),
      ('keep it down', 'yes', 'quiet'),
      ('too loud', 'yes', 'quiet'),
      ('pipe down', 'yes', 'quiet'),
    ]);

    missTable(const ['stop that noise']);
  });

  group('startle', () {
    moodTable(const [
      ('boo', 'startled', 'startle'),
      ('surprise', 'startled', 'startle'),
      ('watch out', 'startled', 'startle'),
    ]);

    missTable(const [
      'boo hoo',
      'surprise party next week',
    ]);
  });

  group('cannot do', () {
    moodTable(const [
      ('can you talk', 'no', 'cannot-do'),
      ('can you sing', 'no', 'cannot-do'),
      ('say something', 'no', 'cannot-do'),
      ('tell me a joke', 'no', 'cannot-do'),
      ('what time is it', 'no', 'cannot-do'),
      ('play some music', 'no', 'cannot-do'),
    ]);

    // Things the body can actually do stay off the list.
    test('dancing is possible',
        () => expectMood('can you dance', 'delighted', 'dance'));
    test('hearing is possible',
        () => expectMood('can you hear me', 'curious', 'greeting'));
  });

  group('confused', () {
    moodTable(const [
      ('huh', 'confused', 'confused'),
      ('what do you mean', 'confused', 'confused'),
      ('did you get that', 'confused', 'confused'),
      ('are you confused', 'confused', 'confused'),
    ]);

    missTable(const ['what should we have for dinner']);
  });

  // -------------------------------------------------------------------------
  // Ordering. These are the pairs where two clusters both match and the
  // position in matchText() is the tie-breaker.
  // -------------------------------------------------------------------------
  group('matcher order', () {
    test('bad bot is a scold, bad day is comfort', () {
      expect(routeReason('bad bot'), 'scold');
      expect(routeReason('bad day'), 'comfort');
    });

    test('silly is teasing, not scolding',
        () => expect(routeReason('silly bot'), 'play'));

    test('a hug request is comfort, not affection', () {
      expect(routeReason('i need a hug'), 'comfort');
      expect(routeReason('give me a hug'), 'affection');
    });

    test('addressed sweetness is praise, bare sweetness is affection', () {
      expect(route('sweet boy'), 'express:happy');
      expect(route("you're sweet"), 'express:love');
    });

    test('bedtime beats both play and farewell', () {
      expect(routeReason("let's go to bed"), 'wind-down');
      expect(routeReason('see you tomorrow'), 'wind-down');
      expect(routeReason('see you later'), 'goodbye');
    });

    test('good night keeps its own reason',
        () => expect(routeReason('good night'), 'good-night'));

    test('quiet outranks annoyance', () {
      expect(routeReason('be quiet'), 'quiet');
      expect(routeReason('enough already'), 'annoyed');
    });

    test('cannot-do outranks the play and greeting nets', () {
      expect(routeReason('play some music'), 'cannot-do');
      expect(routeReason('say hi'), 'cannot-do');
    });
  });

  group('plain chatter reaches the LLM', () {
    missTable(const [
      '',
      '   ',
      'I have a meeting at five',
      'open the pod bay doors',
      'I need to buy a new robot',
      'give me a second',
      'hold on a minute',
    ]);
  });
}
