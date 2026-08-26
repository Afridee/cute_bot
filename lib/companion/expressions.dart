/// Cute mute-bot expressions.
///
/// The model calls `express(mood)` once per turn. This table expands a mood
/// into LED / sound / wiggle so personality can be tuned here without
/// touching the prompt or the BLE primitives.
library;

import 'brain/brain_session.dart';

/// Moods the model may name. Keep this list and the `express` tool enum
/// in lockstep — [BotMood.values] is the schema.
enum BotMood {
  curious,
  happy,
  delighted,
  love,
  playful,
  startled,
  confused,
  sleepy,
  sad,
  annoyed,
  proud,
  yes,
  no,
  alarm,
  // ignore: constant_identifier_names — tool-schema name, not a Dart constant.
  low_battery,
}

/// One canned body pose. [color] / [pattern] / [sound] use the same
/// names as [ledColor] / [ledPattern] / [botSound] in BotBody.
final class ExpressionSpec {
  const ExpressionSpec({
    required this.mood,
    required this.color,
    required this.pattern,
    this.sound,
    this.wiggle = false,
  });

  final BotMood mood;
  final String color;
  final String pattern;

  /// `chirp`, `beep`, `purr`, or null for silence.
  final String? sound;
  final bool wiggle;
}

/// Lookup table. Every [BotMood] has a row.
const Map<BotMood, ExpressionSpec> kExpressions = {
  BotMood.curious: ExpressionSpec(
    mood: BotMood.curious,
    color: 'cyan',
    pattern: 'breathe',
  ),
  BotMood.happy: ExpressionSpec(
    mood: BotMood.happy,
    color: 'pink',
    pattern: 'blink',
    sound: 'chirp',
  ),
  BotMood.delighted: ExpressionSpec(
    mood: BotMood.delighted,
    color: 'pink',
    pattern: 'blink',
    sound: 'chirp',
    wiggle: true,
  ),
  BotMood.love: ExpressionSpec(
    mood: BotMood.love,
    color: 'pink',
    pattern: 'breathe',
    sound: 'purr',
  ),
  BotMood.playful: ExpressionSpec(
    mood: BotMood.playful,
    color: 'cyan',
    pattern: 'blink',
    sound: 'chirp',
    wiggle: true,
  ),
  BotMood.startled: ExpressionSpec(
    mood: BotMood.startled,
    color: 'yellow',
    pattern: 'blink',
    sound: 'beep',
  ),
  BotMood.confused: ExpressionSpec(
    mood: BotMood.confused,
    color: 'purple',
    pattern: 'blink',
  ),
  BotMood.sleepy: ExpressionSpec(
    mood: BotMood.sleepy,
    color: 'blue',
    pattern: 'breathe',
    sound: 'purr',
  ),
  BotMood.sad: ExpressionSpec(
    mood: BotMood.sad,
    color: 'blue',
    pattern: 'solid',
  ),
  BotMood.annoyed: ExpressionSpec(
    mood: BotMood.annoyed,
    color: 'orange',
    pattern: 'blink',
    sound: 'beep',
  ),
  BotMood.proud: ExpressionSpec(
    mood: BotMood.proud,
    color: 'yellow',
    pattern: 'solid',
    sound: 'chirp',
  ),
  BotMood.yes: ExpressionSpec(
    mood: BotMood.yes,
    color: 'green',
    pattern: 'blink',
    sound: 'chirp',
  ),
  BotMood.no: ExpressionSpec(
    mood: BotMood.no,
    color: 'red',
    pattern: 'blink',
  ),
  BotMood.alarm: ExpressionSpec(
    mood: BotMood.alarm,
    color: 'yellow',
    pattern: 'blink',
    sound: 'beep',
  ),
  BotMood.low_battery: ExpressionSpec(
    mood: BotMood.low_battery,
    color: 'red',
    pattern: 'breathe',
    sound: 'beep',
  ),
};

/// Resolves a tool argument to a spec. Unknown / missing mood → null.
ExpressionSpec? expressionFor(Object? mood) {
  final name = '$mood';
  for (final m in BotMood.values) {
    if (m.name == name) return kExpressions[m];
  }
  return null;
}

/// Phone-only lifecycle faces. Not exposed to Gemma — maps brain state to
/// an existing catalog row while warming or inferencing.
BotMood? systemMoodForBrainState(BrainSessionState state) => switch (state) {
      BrainSessionState.thinking => BotMood.curious,
      BrainSessionState.warming => BotMood.sleepy,
      _ => null,
    };
