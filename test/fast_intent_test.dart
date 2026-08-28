import 'package:cute_bot/companion/brain/fast_intent.dart';
import 'package:cute_bot/companion/brain/fast_intent_overlay.dart';
import 'package:cute_bot/companion/expressions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('persona few-shots', () {
    test('hey little guy, you awake? → curious', () {
      final hit = matchText('hey little guy, you awake?');
      expect(hit, isNotNull);
      expect(hit!.reason, 'greeting');
      expect(hit.calls.single.transcriptLine, 'express(curious)');
    });

    test('set a timer for three minutes, tea', () {
      final hit = matchText('set a timer for three minutes, tea');
      expect(hit, isNotNull);
      expect(hit!.calls.single.transcriptLine, 'set_timer(3, tea)');
    });

    test('how much battery do you have?', () {
      final hit = matchText('how much battery do you have?');
      expect(hit, isNotNull);
      expect(hit!.calls.single.transcriptLine, 'get_battery()');
    });

    test('do a little dance', () {
      final hit = matchText('do a little dance');
      expect(hit!.calls.single.transcriptLine, 'express(delighted)');
    });

    test('timer fire cue', () {
      final hit = matchText("A timer just finished: 'tea'. Call express(alarm).");
      expect(hit!.calls.single.transcriptLine, 'express(alarm)');
    });
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

    test('two hours becomes 120', () {
      expect(
        matchText('start a timer for two hours, bread')!.calls.single.arguments,
        {'minutes': 120, 'label': 'bread'},
      );
    });

    test('over 180 minutes is a miss (BotBody would reject)', () {
      expect(matchText('set a timer for four hours'), isNull);
    });

    test('timer without a duration is a miss', () {
      expect(matchText('set a timer'), isNull);
    });

    test('remind me in ten minutes', () {
      final call = matchText('remind me in ten minutes')!.calls.single;
      expect(call.arguments['minutes'], 10);
    });

    test('half an hour becomes 30', () {
      final call = matchText('set a timer for half an hour')!.calls.single;
      expect(call.arguments['minutes'], 30);
      expect(call.arguments['label'], 'timer');
    });

    test('an hour and a half becomes 90', () {
      final call =
          matchText('set a timer for an hour and a half, bread')!.calls.single;
      expect(call.arguments['minutes'], 90);
      expect(call.arguments['label'], 'bread');
    });

    test('two and a half hours becomes 150', () {
      final call =
          matchText('start a timer for two and a half hours')!.calls.single;
      expect(call.arguments['minutes'], 150);
    });

    test('three and a half hours exceeds the cap', () {
      expect(matchText('set a timer for three and a half hours'), isNull);
    });

    test('wake me up in twenty minutes', () {
      final call = matchText('wake me up in twenty minutes')!.calls.single;
      expect(call.arguments['minutes'], 20);
    });

    test('countdown ten minutes', () {
      final call = matchText('countdown ten minutes')!.calls.single;
      expect(call.arguments['minutes'], 10);
    });

    test('Set timer for 20 seconds is seconds, not minutes', () {
      final call = matchText('Set timer for 20 seconds')!.calls.single;
      expect(call.name, 'set_timer');
      expect(call.arguments['seconds'], 20);
      expect(call.arguments.containsKey('minutes'), isFalse);
      expect(call.arguments['label'], 'timer');
    });

    test('set a timer for 20 seconds', () {
      expect(matchText('set a timer for 20 seconds')!.calls.single.arguments,
          {'seconds': 20, 'label': 'timer'});
    });

    test('twenty seconds as words', () {
      expect(
        matchText('set a timer for twenty seconds')!.calls.single.arguments['seconds'],
        20,
      );
    });

    test('20 second timer (unit before timer)', () {
      final call = matchText('20 second timer')!.calls.single;
      expect(call.arguments['seconds'], 20);
    });

    test('hyphenated 20-second timer', () {
      expect(matchText('set a 20-second timer')!.calls.single.arguments['seconds'],
          20);
    });

    test('remind me in 15 seconds', () {
      expect(matchText('remind me in 15 seconds')!.calls.single.arguments['seconds'],
          15);
    });

    test('time me for 10 seconds', () {
      expect(matchText('time me for 10 seconds')!.calls.single.arguments['seconds'],
          10);
    });

    test('ASR near-miss diamer still sets seconds', () {
      final call =
          matchText('START THE DIAMER FOR TWENTY SECONDS')!.calls.single;
      expect(call.name, 'set_timer');
      expect(call.arguments['seconds'], 20);
      expect(call.arguments.containsKey('minutes'), isFalse);
    });

    test('ASR near-miss dimer still sets minutes', () {
      final call =
          matchText('CAN YOU SAID THE DIMER FOR TWO MINUTES')!.calls.single;
      expect(call.name, 'set_timer');
      expect(call.arguments['minutes'], 2);
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

    test('distance-3 noun with a duration stays chatter', () {
      expect(matchText('start the dinner for two minutes'), isNull);
    });

    test('I need a timer for 30 seconds', () {
      expect(
        matchText('I need a timer for 30 seconds')!.calls.single.arguments['seconds'],
        30,
      );
    });

    test('1 minute 20 seconds is mixed', () {
      final call =
          matchText('set a timer for 1 minute 20 seconds, tea')!.calls.single;
      expect(call.arguments['minutes'], 1);
      expect(call.arguments['seconds'], 20);
      expect(call.arguments['label'], 'tea');
    });

    test('90 seconds is 1 minute 30 seconds', () {
      final call = matchText('start a timer for 90 seconds')!.calls.single;
      expect(call.arguments['minutes'], 1);
      expect(call.arguments['seconds'], 30);
    });

    test('a couple of seconds', () {
      expect(
        matchText('set a timer for a couple of seconds')!.calls.single.arguments['seconds'],
        2,
      );
    });

    test('start the timer for 20 seconds is set, not resume', () {
      expect(matchText('start the timer for 20 seconds')!.reason, 'set-timer');
      expect(
        matchText('start the timer for 20 seconds')!.calls.single.arguments['seconds'],
        20,
      );
    });
  });

  group('timer control', () {
    test('cancel the timer', () {
      final hit = matchText('cancel the timer');
      expect(hit, isNotNull);
      expect(hit!.reason, 'cancel-timer');
      expect(hit.calls.single.transcriptLine, 'cancel_timer()');
    });

    test('stop the timer', () {
      expect(matchText('stop the timer')!.calls.single.transcriptLine,
          'cancel_timer()');
    });

    test('kill the timer is cancel', () {
      expect(matchText('kill the timer')!.reason, 'cancel-timer');
    });

    test('forget the tea timer keeps the label', () {
      expect(matchText('forget the tea timer')!.calls.single.arguments['label'],
          'tea');
    });

    test('cancel the tea timer keeps the label', () {
      final call = matchText('cancel the tea timer')!.calls.single;
      expect(call.name, 'cancel_timer');
      expect(call.arguments['label'], 'tea');
    });

    test('freeze the timer is pause', () {
      expect(matchText('freeze the timer')!.reason, 'pause-timer');
    });

    test('pause the tea timer', () {
      expect(matchText('pause the tea timer')!.calls.single.arguments['label'],
          'tea');
    });

    test('resume the timer', () {
      expect(matchText('resume the timer')!.calls.single.transcriptLine,
          'resume_timer()');
    });

    test('start the timer (no duration) is resume', () {
      expect(matchText('start the timer')!.reason, 'resume-timer');
    });

    test('start the timer for 5 minutes is still set', () {
      expect(matchText('start the timer for 5 minutes')!.reason, 'set-timer');
    });

    test('unpause the countdown', () {
      expect(matchText('unpause the countdown')!.reason, 'resume-timer');
    });
  });

  group('precision', () {
    test('negation does not arm a timer', () {
      expect(matchText("don't set a timer for 3 minutes"), isNull);
      expect(matchText("don't cancel the timer"), isNull);
    });

    test('open-ended chatter is a miss', () {
      expect(matchText('tell me a joke'), isNull);
      expect(matchText('what time is it'), isNull);
      expect(matchText('I am feeling a bit sad today'), isNull);
      expect(matchText('20 seconds'), isNull);
      expect(matchText('give me 20 seconds'), isNull);
    });

    test('empty is a miss', () {
      expect(matchText(''), isNull);
      expect(matchText('   '), isNull);
    });
  });

  group('other moods', () {
    test('good night is sleepy', () {
      expect(matchText('good night little guy')!.calls.single.arguments['mood'],
          'sleepy');
    });

    test('love you', () {
      expect(matchText('I love you')!.calls.single.transcriptLine,
          'express(love)');
    });

    test('good bot', () {
      expect(matchText('good bot')!.calls.single.transcriptLine, 'express(happy)');
    });
  });

  group('capability no', () {
    test('can you talk → no', () {
      expect(matchText('can you talk?')!.calls.single.transcriptLine,
          'express(no)');
    });

    test('say something → no', () {
      expect(matchText('say something')!.calls.single.arguments['mood'], 'no');
    });

    test('can you set a timer stays a miss (no duration)', () {
      expect(matchText('can you set a timer'), isNull);
    });
  });

  group('play and startle', () {
    test('wanna play → playful', () {
      expect(matchText('wanna play?')!.calls.single.arguments['mood'],
          'playful');
    });

    test('peekaboo → playful', () {
      expect(
          matchText('peekaboo!')!.calls.single.arguments['mood'], 'playful');
    });

    test('boo → startled', () {
      expect(matchText('boo!')!.calls.single.arguments['mood'], 'startled');
    });

    test('surprise → startled', () {
      expect(
          matchText('surprise!')!.calls.single.arguments['mood'], 'startled');
    });

    test('boogie is a dance, not a startle', () {
      expect(matchText('boogie time')!.reason, 'dance');
    });
  });

  group('thanks and praise', () {
    test('thank you → happy', () {
      expect(matchText('thank you buddy')!.calls.single.arguments['mood'],
          'happy');
    });

    test('well done → proud', () {
      expect(matchText('well done!')!.calls.single.arguments['mood'], 'proud');
    });

    test('you did it → proud', () {
      expect(matchText('you did it!')!.reason, 'well-done');
    });
  });

  group('scold and comfort', () {
    test('bad bot → sad via scold', () {
      final hit = matchText('bad bot')!;
      expect(hit.reason, 'scold');
      expect(hit.calls.single.arguments['mood'], 'sad');
    });

    test('bad day is comfort, not scold', () {
      final hit = matchText('I had a bad day')!;
      expect(hit.reason, 'comfort');
      expect(hit.calls.single.arguments['mood'], 'sad');
    });

    test("i'm sad → comfort", () {
      expect(matchText("i'm sad")!.reason, 'comfort');
    });

    test('open-ended sadness still goes to the LLM', () {
      expect(matchText('I am feeling a bit sad today'), isNull);
    });
  });

  group('quiet', () {
    test('be quiet → yes', () {
      expect(matchText('be quiet')!.calls.single.arguments['mood'], 'yes');
    });

    test('shhh → yes', () {
      expect(matchText('shhh')!.reason, 'quiet');
    });

    test('stop beeping stays a miss', () {
      expect(matchText('stop beeping'), isNull);
    });
  });

  group('farewells', () {
    test('go to sleep → sleepy', () {
      expect(
          matchText('go to sleep')!.calls.single.arguments['mood'], 'sleepy');
    });

    test('sweet dreams → sleepy', () {
      expect(matchText('sweet dreams little guy')!.reason, 'wind-down');
    });

    test('see you tomorrow → sleepy', () {
      expect(matchText('see you tomorrow')!.calls.single.arguments['mood'],
          'sleepy');
    });

    test('bye bye → sad', () {
      expect(matchText('bye bye')!.calls.single.arguments['mood'], 'sad');
    });

    test('goodbye → sad', () {
      expect(matchText('goodbye!')!.reason, 'goodbye');
    });

    test('gotta go → sad', () {
      expect(matchText('gotta go')!.calls.single.arguments['mood'], 'sad');
    });
  });

  group('expanded keywords', () {
    test('are you charged → get_battery', () {
      expect(matchText('are you charged?')!.calls.single.transcriptLine,
          'get_battery()');
    });

    test('running low → get_battery', () {
      expect(matchText('running low?')!.reason, 'battery');
    });

    test('shake it → delighted', () {
      expect(matchText('shake it!')!.calls.single.arguments['mood'],
          'delighted');
    });

    test("you're adorable → love", () {
      expect(matchText("you're adorable")!.calls.single.arguments['mood'],
          'love');
    });

    test('i missed you → love', () {
      expect(matchText('i missed you')!.reason, 'affection');
    });

    test('love ya → love', () {
      expect(matchText('love ya')!.calls.single.arguments['mood'], 'love');
    });

    test('good evening → curious', () {
      expect(matchText('good evening')!.calls.single.arguments['mood'],
          'curious');
    });

    test("what's up → curious", () {
      expect(matchText("what's up")!.reason, 'greeting');
    });

    test('howdy → curious', () {
      expect(matchText('howdy')!.calls.single.arguments['mood'], 'curious');
    });
  });

  group('overlay', () {
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
      expect(matchText('pause the timer', overlay)!.reason, 'pause-timer');
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
}
