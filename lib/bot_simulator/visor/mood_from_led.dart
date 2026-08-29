// Reverse of the companion's expression table: the wire only carries
// set_led(r, g, b, pattern), so the visor infers the mood from the LED
// signature. Kept in lockstep with `ledColor` / `kExpressions` in
// lib/companion/expressions.dart + bot_body.dart (not imported — the
// simulator is the bot side and stays firmware-portable).
//
// Known collisions in the catalog:
// - happy vs delighted are both pink+blink; a wiggle arriving after the
//   LED write upgrades to delighted (`recentWiggle`).
// - startled vs alarm are both yellow+blink+beep and are byte-identical
//   on the wire. We show startled; alarm gets its own face once firmware
//   grows an express(mood) control command.

import '../../shared/ble_protocol.dart';
import 'face_pose.dart';

/// Named LED colors as the companion sends them (see `ledColor`).
const Map<String, (int, int, int)> _wireColors = {
  'red': (255, 0, 0),
  'green': (0, 255, 0),
  'blue': (0, 60, 255),
  'pink': (255, 105, 180),
  'purple': (160, 0, 255),
  'yellow': (255, 200, 0),
  'orange': (255, 120, 0),
  'white': (255, 255, 255),
  'cyan': (0, 200, 255),
};

/// Maps one LED command to the visor mood to display.
///
/// [recentWiggle] should be true when a wiggle command arrived after this
/// LED write (the companion sends led → sound → wiggle for wiggly moods).
VisorMood visorMoodForLed({
  required int red,
  required int green,
  required int blue,
  required LedPattern pattern,
  bool recentWiggle = false,
}) {
  if (pattern == LedPattern.off || (red == 0 && green == 0 && blue == 0)) {
    return VisorMood.neutral;
  }

  final name = _nearestColorName(red, green, blue);
  final mood = switch ((name, pattern)) {
    ('cyan', LedPattern.breathe) => VisorMood.curious,
    ('cyan', LedPattern.blink) => VisorMood.playful,
    ('pink', LedPattern.blink) =>
      recentWiggle ? VisorMood.delighted : VisorMood.happy,
    ('pink', LedPattern.breathe) => VisorMood.love,
    ('yellow', LedPattern.blink) => VisorMood.startled,
    ('yellow', LedPattern.solid) => VisorMood.proud,
    ('purple', LedPattern.blink) => VisorMood.confused,
    // System lifecycle signature — the companion sends this while the
    // brain is processing an utterance (not a model-expressible mood).
    ('purple', LedPattern.breathe) => VisorMood.thinking,
    ('blue', LedPattern.breathe) => VisorMood.sleepy,
    ('blue', LedPattern.solid) => VisorMood.sad,
    ('orange', LedPattern.blink) => VisorMood.annoyed,
    ('green', LedPattern.blink) => VisorMood.yes,
    ('red', LedPattern.blink) => VisorMood.no,
    ('red', LedPattern.breathe) => VisorMood.lowBattery,
    _ => VisorMood.neutral,
  };
  return mood;
}

/// Nearest catalog color by squared RGB distance, so a slightly
/// off-catalog write (future firmware, manual tools) still lands on a
/// sensible face.
String _nearestColorName(int r, int g, int b) {
  var bestName = 'cyan';
  var bestDistance = 1 << 30;
  for (final entry in _wireColors.entries) {
    final (cr, cg, cb) = entry.value;
    final d = (r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb);
    if (d < bestDistance) {
      bestDistance = d;
      bestName = entry.key;
    }
  }
  return bestName;
}
