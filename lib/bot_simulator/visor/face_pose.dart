// Parametric visor face: every expression is a set of numbers, so any
// two expressions can be interpolated for a smooth morph. This is the
// simulator's stand-in for the ESP32 eye engine — keep it portable
// (pure geometry, no widget or controller imports).

import 'dart:math' as math;
import 'dart:ui';

/// Moods the visor can render. Mirrors `BotMood` in the companion plus a
/// [neutral] resting face for when the LED is off. Kept as a separate enum
/// so the simulator (bot side) does not import companion brain code.
enum VisorMood {
  neutral,
  thinking,
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
  lowBattery,
}

/// One eye as interpolatable parameters.
///
/// The base shape is an arc of a circle: [centerAngle] says which part of
/// the circle is drawn (canvas angles, `-pi/2` = top) and [sweep] how much
/// of it (`2*pi` = full ring). That single primitive covers rings, discs,
/// happy ∩ arcs, sad ∪ arcs, and — squashed and tilted — sleepy lids and
/// annoyed slants. Hearts and the playful `<` are separate shapes that
/// crossfade in via [heart] / [chevron].
final class EyePose {
  const EyePose({
    this.centerAngle = -math.pi / 2,
    this.sweep = math.pi * 2,
    this.radius = 1.0,
    this.stroke = 0.30,
    this.fill = 0.0,
    this.squash = 1.0,
    this.tilt = 0.0,
    this.offset = Offset.zero,
    this.pupil = 0.0,
    this.pupilOffset = Offset.zero,
    this.heart = 0.0,
    this.chevron = 0.0,
    this.rays = 0.0,
    this.sparkle = 0.0,
    this.sparkleOffset = Offset.zero,
    this.brow = 0.0,
  });

  /// Canvas angle of the arc midpoint. `-pi/2` is the top of the circle.
  final double centerAngle;

  /// Arc length in radians. `2*pi` draws the whole circle.
  final double sweep;

  /// Eye size, relative to the painter's base eye radius.
  final double radius;

  /// Stroke width relative to [radius].
  final double stroke;

  /// 0 = outline only (ring / arc), 1 = filled disc.
  final double fill;

  /// Vertical scale. 1 = round, →0 = closed lid. Blinks multiply this.
  final double squash;

  /// Rotation in radians (annoyed / no slants).
  final double tilt;

  /// Eye position offset relative to [radius] (droop, nod, shake).
  final Offset offset;

  /// Dark pupil opacity (curious). Position via [pupilOffset].
  final double pupil;
  final Offset pupilOffset;

  /// Crossfade weights for alternate shapes / decorations, all 0..1.
  final double heart;
  final double chevron;
  final double rays;
  final double sparkle;
  final Offset sparkleOffset;
  final double brow;

  EyePose copyWith({
    double? centerAngle,
    double? sweep,
    double? radius,
    double? stroke,
    double? fill,
    double? squash,
    double? tilt,
    Offset? offset,
    double? pupil,
    Offset? pupilOffset,
    double? heart,
    double? chevron,
    double? rays,
    double? sparkle,
    Offset? sparkleOffset,
    double? brow,
  }) {
    return EyePose(
      centerAngle: centerAngle ?? this.centerAngle,
      sweep: sweep ?? this.sweep,
      radius: radius ?? this.radius,
      stroke: stroke ?? this.stroke,
      fill: fill ?? this.fill,
      squash: squash ?? this.squash,
      tilt: tilt ?? this.tilt,
      offset: offset ?? this.offset,
      pupil: pupil ?? this.pupil,
      pupilOffset: pupilOffset ?? this.pupilOffset,
      heart: heart ?? this.heart,
      chevron: chevron ?? this.chevron,
      rays: rays ?? this.rays,
      sparkle: sparkle ?? this.sparkle,
      sparkleOffset: sparkleOffset ?? this.sparkleOffset,
      brow: brow ?? this.brow,
    );
  }

  static EyePose lerp(EyePose a, EyePose b, double t) {
    double d(double x, double y) => x + (y - x) * t;
    return EyePose(
      centerAngle: d(a.centerAngle, b.centerAngle),
      sweep: d(a.sweep, b.sweep),
      radius: d(a.radius, b.radius),
      stroke: d(a.stroke, b.stroke),
      fill: d(a.fill, b.fill),
      squash: d(a.squash, b.squash),
      tilt: d(a.tilt, b.tilt),
      offset: Offset.lerp(a.offset, b.offset, t)!,
      pupil: d(a.pupil, b.pupil),
      pupilOffset: Offset.lerp(a.pupilOffset, b.pupilOffset, t)!,
      heart: d(a.heart, b.heart),
      chevron: d(a.chevron, b.chevron),
      rays: d(a.rays, b.rays),
      sparkle: d(a.sparkle, b.sparkle),
      sparkleOffset: Offset.lerp(a.sparkleOffset, b.sparkleOffset, t)!,
      brow: d(a.brow, b.brow),
    );
  }
}

/// A whole visor frame: two eyes, glow color, battery-icon opacity.
final class FacePose {
  const FacePose({
    required this.left,
    required this.right,
    required this.color,
    this.battery = 0.0,
    this.thoughtDots = 0.0,
    this.dotPhase = 0.0,
  });

  final EyePose left;
  final EyePose right;
  final Color color;

  /// Opacity of the low-battery icon in the visor corner.
  final double battery;

  /// Opacity of the "..." thought ellipsis (thinking mood).
  final double thoughtDots;

  /// 0..1 cycle position driving the sequential dot pulse.
  final double dotPhase;

  FacePose copyWith({
    EyePose? left,
    EyePose? right,
    Color? color,
    double? battery,
    double? thoughtDots,
    double? dotPhase,
  }) {
    return FacePose(
      left: left ?? this.left,
      right: right ?? this.right,
      color: color ?? this.color,
      battery: battery ?? this.battery,
      thoughtDots: thoughtDots ?? this.thoughtDots,
      dotPhase: dotPhase ?? this.dotPhase,
    );
  }

  static FacePose lerp(FacePose a, FacePose b, double t) {
    return FacePose(
      left: EyePose.lerp(a.left, b.left, t),
      right: EyePose.lerp(a.right, b.right, t),
      color: Color.lerp(a.color, b.color, t)!,
      battery: a.battery + (b.battery - a.battery) * t,
      thoughtDots: a.thoughtDots + (b.thoughtDots - a.thoughtDots) * t,
      dotPhase: a.dotPhase + (b.dotPhase - a.dotPhase) * t,
    );
  }

  /// Target pose for one mood — the still frame the visor morphs toward.
  static FacePose of(VisorMood mood) => _catalog[mood]!;
}

// Screen-sheet palette: cyan default, pink for love, red for alarm and
// low battery. (The physical LED color is a separate wire concern.)
const Color _cyan = Color(0xFF3ADCFF);
const Color _pink = Color(0xFFFF6EC7);
const Color _red = Color(0xFFFF4A3D);
const Color _purple = Color(0xFFB57CFF);

const EyePose _happyArc = EyePose(
  centerAngle: -math.pi / 2,
  sweep: math.pi,
  stroke: 0.34,
);

const EyePose _sadArc = EyePose(
  centerAngle: math.pi / 2,
  sweep: math.pi,
  stroke: 0.34,
  offset: Offset(0, 0.15),
);

const EyePose _ring = EyePose(sweep: math.pi * 2, stroke: 0.30);

const EyePose _disc = EyePose(sweep: math.pi * 2, fill: 1.0, stroke: 0.10);

final Map<VisorMood, FacePose> _catalog = {
  VisorMood.neutral: FacePose(
    left: _disc.copyWith(radius: 0.82, squash: 0.95),
    right: _disc.copyWith(radius: 0.82, squash: 0.95),
    color: _cyan,
  ),
  VisorMood.thinking: FacePose(
    // Concentrating: narrowed asymmetric eyes fixated up-left, one brow
    // faintly furrowed, thought ellipsis on.
    left: _disc.copyWith(
      radius: 0.88,
      squash: 0.68,
      pupil: 1.0,
      pupilOffset: const Offset(-0.30, -0.22),
      brow: 0.5,
    ),
    right: _disc.copyWith(
      radius: 0.88,
      squash: 0.82,
      pupil: 1.0,
      pupilOffset: const Offset(-0.30, -0.22),
    ),
    color: _purple,
    thoughtDots: 1.0,
  ),
  VisorMood.curious: FacePose(
    left: _disc.copyWith(
      radius: 0.92,
      pupil: 1.0,
      pupilOffset: const Offset(0.30, -0.18),
    ),
    right: _disc.copyWith(
      radius: 1.0,
      pupil: 1.0,
      pupilOffset: const Offset(0.30, -0.18),
    ),
    color: _cyan,
  ),
  VisorMood.happy: const FacePose(left: _happyArc, right: _happyArc, color: _cyan),
  VisorMood.delighted: FacePose(
    left: _happyArc.copyWith(rays: 1.0),
    right: _happyArc.copyWith(rays: 1.0),
    color: _cyan,
  ),
  VisorMood.love: const FacePose(
    left: EyePose(heart: 1.0, stroke: 0.1),
    right: EyePose(heart: 1.0, stroke: 0.1),
    color: _pink,
  ),
  VisorMood.playful: const FacePose(
    left: _happyArc,
    right: EyePose(chevron: 1.0, stroke: 0.30),
    color: _cyan,
  ),
  VisorMood.startled: FacePose(
    left: _ring.copyWith(radius: 1.05, rays: 1.0),
    right: _ring.copyWith(radius: 1.05, rays: 1.0),
    color: _cyan,
  ),
  VisorMood.confused: FacePose(
    left: _happyArc.copyWith(radius: 0.78, brow: 1.0),
    right: _ring.copyWith(radius: 0.95, tilt: -0.12),
    color: _cyan,
  ),
  VisorMood.sleepy: const FacePose(
    left: EyePose(
      centerAngle: math.pi / 2,
      sweep: math.pi * 0.9,
      squash: 0.32,
      stroke: 0.46,
    ),
    right: EyePose(
      centerAngle: math.pi / 2,
      sweep: math.pi * 0.9,
      squash: 0.32,
      stroke: 0.46,
    ),
    color: _cyan,
  ),
  VisorMood.sad: const FacePose(left: _sadArc, right: _sadArc, color: _cyan),
  VisorMood.annoyed: FacePose(
    left: _happyArc.copyWith(squash: 0.45, stroke: 0.50, tilt: 0.40),
    right: _happyArc.copyWith(squash: 0.45, stroke: 0.50, tilt: -0.40),
    color: _cyan,
  ),
  VisorMood.proud: FacePose(
    left: _happyArc.copyWith(
      sparkle: 1.0,
      sparkleOffset: const Offset(-1.1, -1.0),
    ),
    right: _happyArc.copyWith(
      sparkle: 1.0,
      sparkleOffset: const Offset(1.1, -1.0),
    ),
    color: _cyan,
  ),
  VisorMood.yes: const FacePose(left: _happyArc, right: _happyArc, color: _cyan),
  VisorMood.no: FacePose(
    left: _happyArc.copyWith(squash: 0.30, stroke: 0.55, sweep: math.pi * 0.7, tilt: 0.45),
    right: _happyArc.copyWith(squash: 0.30, stroke: 0.55, sweep: math.pi * 0.7, tilt: -0.45),
    color: _cyan,
  ),
  VisorMood.alarm: FacePose(
    left: _ring.copyWith(radius: 1.10, rays: 1.0, stroke: 0.34),
    right: _ring.copyWith(radius: 1.10, rays: 1.0, stroke: 0.34),
    color: _red,
  ),
  VisorMood.lowBattery: FacePose(
    left: _sadArc.copyWith(squash: 0.6),
    right: _sadArc.copyWith(squash: 0.6),
    color: _red,
    battery: 1.0,
  ),
};
