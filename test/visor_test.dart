// Visor tests: the wire→mood mapping stays in lockstep with the
// companion's expression catalog, poses interpolate cleanly, and the
// animated widget survives mood changes without throwing.

import 'package:cute_bot/bot_simulator/visor/bot_visor.dart';
import 'package:cute_bot/bot_simulator/visor/face_pose.dart';
import 'package:cute_bot/bot_simulator/visor/mood_from_led.dart';
import 'package:cute_bot/shared/ble_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('visorMoodForLed', () {
    VisorMood forLed(
      (int, int, int) rgb,
      LedPattern pattern, {
      bool recentWiggle = false,
    }) {
      return visorMoodForLed(
        red: rgb.$1,
        green: rgb.$2,
        blue: rgb.$3,
        pattern: pattern,
        recentWiggle: recentWiggle,
      );
    }

    // RGB tuples as `ledColor` in bot_body.dart sends them.
    const cyan = (0, 200, 255);
    const pink = (255, 105, 180);
    const yellow = (255, 200, 0);
    const purple = (160, 0, 255);
    const blue = (0, 60, 255);
    const orange = (255, 120, 0);
    const green = (0, 255, 0);
    const red = (255, 0, 0);

    test('maps every expression-catalog wire signature', () {
      expect(forLed(cyan, LedPattern.breathe), VisorMood.curious);
      expect(forLed(cyan, LedPattern.blink), VisorMood.playful);
      expect(forLed(pink, LedPattern.blink), VisorMood.happy);
      expect(
        forLed(pink, LedPattern.blink, recentWiggle: true),
        VisorMood.delighted,
      );
      expect(forLed(pink, LedPattern.breathe), VisorMood.love);
      // Alarm is byte-identical to startled on the wire; startled wins.
      expect(forLed(yellow, LedPattern.blink), VisorMood.startled);
      expect(forLed(yellow, LedPattern.solid), VisorMood.proud);
      expect(forLed(purple, LedPattern.blink), VisorMood.confused);
      expect(forLed(blue, LedPattern.breathe), VisorMood.sleepy);
      expect(forLed(blue, LedPattern.solid), VisorMood.sad);
      expect(forLed(orange, LedPattern.blink), VisorMood.annoyed);
      expect(forLed(green, LedPattern.blink), VisorMood.yes);
      expect(forLed(red, LedPattern.blink), VisorMood.no);
      expect(forLed(red, LedPattern.breathe), VisorMood.lowBattery);
    });

    test('off pattern or black is the neutral resting face', () {
      expect(forLed(cyan, LedPattern.off), VisorMood.neutral);
      expect(forLed((0, 0, 0), LedPattern.solid), VisorMood.neutral);
    });

    test('slightly off-catalog color snaps to the nearest face', () {
      expect(forLed((250, 100, 175), LedPattern.blink), VisorMood.happy);
      expect(forLed((10, 190, 250), LedPattern.breathe), VisorMood.curious);
    });

    test('unknown signature falls back to neutral', () {
      expect(forLed((255, 255, 255), LedPattern.blink), VisorMood.neutral);
    });
  });

  group('FacePose', () {
    test('every mood has a pose and the marker features are set', () {
      for (final mood in VisorMood.values) {
        expect(FacePose.of(mood), isNotNull, reason: mood.name);
      }
      expect(FacePose.of(VisorMood.love).left.heart, 1.0);
      expect(FacePose.of(VisorMood.playful).right.chevron, 1.0);
      expect(FacePose.of(VisorMood.startled).left.rays, 1.0);
      expect(FacePose.of(VisorMood.proud).left.sparkle, 1.0);
      expect(FacePose.of(VisorMood.confused).left.brow, 1.0);
      expect(FacePose.of(VisorMood.curious).right.pupil, 1.0);
      expect(FacePose.of(VisorMood.lowBattery).battery, 1.0);
    });

    test('lerp hits both endpoints and the midpoint moves', () {
      final happy = FacePose.of(VisorMood.happy);
      final love = FacePose.of(VisorMood.love);

      final at0 = FacePose.lerp(happy, love, 0);
      expect(at0.left.heart, happy.left.heart);
      expect(at0.color, happy.color);

      final at1 = FacePose.lerp(happy, love, 1);
      expect(at1.left.heart, love.left.heart);
      expect(at1.color, love.color);

      final mid = FacePose.lerp(happy, love, 0.5);
      expect(mid.left.heart, closeTo(0.5, 1e-9));
      expect(mid.left.sweep, closeTo((happy.left.sweep + love.left.sweep) / 2, 1e-9));
      expect(mid.color, isNot(happy.color));
      expect(mid.color, isNot(love.color));
    });
  });

  group('BotVisor widget', () {
    testWidgets('animates and survives mood changes', (tester) async {
      Widget wrap(VisorMood mood) => Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(width: 400, child: BotVisor(mood: mood)),
            ),
          );

      await tester.pumpWidget(wrap(VisorMood.neutral));
      await tester.pump(const Duration(milliseconds: 100));

      // Morph through several very different shapes, pumping mid-morph.
      for (final mood in [
        VisorMood.curious,
        VisorMood.love,
        VisorMood.playful,
        VisorMood.alarm,
        VisorMood.lowBattery,
      ]) {
        await tester.pumpWidget(wrap(mood));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 400));
      }

      // Long idle to cross a blink cycle.
      await tester.pumpWidget(wrap(VisorMood.happy));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.takeException(), isNull);
    });
  });
}
