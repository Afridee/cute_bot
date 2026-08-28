// The bot's face: a black visor bezel with two animated eyes.
//
// Three layers of motion, all on one ticker:
// 1. Morph — when the mood changes, the previous pose eases into the new
//    one over ~350 ms (every parameter interpolates, so arcs bend into
//    rings, color fades cyan→red, hearts crossfade in).
// 2. Idle — each mood has a small procedural loop (pupil wander, nod,
//    sparkle twinkle) so the face never freezes.
// 3. Blink — a periodic lid squash on top of everything, skipped for
//    moods whose idle already owns the lids.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'face_painter.dart';
import 'face_pose.dart';

class BotVisor extends StatefulWidget {
  const BotVisor({super.key, required this.mood});

  final VisorMood mood;

  @override
  State<BotVisor> createState() => _BotVisorState();
}

class _BotVisorState extends State<BotVisor>
    with SingleTickerProviderStateMixin {
  static const double _morphSeconds = 0.35;

  late final Ticker _ticker;
  final ValueNotifier<double> _time = ValueNotifier(0);
  final math.Random _random = math.Random();

  late FacePose _from;
  late FacePose _to;
  double _morphStart = -_morphSeconds; // start settled, not mid-morph

  double _nextBlinkAt = 1.5;
  double _blinkStart = -1;

  @override
  void initState() {
    super.initState();
    _from = FacePose.of(widget.mood);
    _to = _from;
    _ticker = createTicker((elapsed) {
      _time.value = elapsed.inMicroseconds / 1e6;
    })
      ..start();
  }

  @override
  void didUpdateWidget(BotVisor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mood != widget.mood) {
      // Retarget from wherever the morph currently is, so rapid mood
      // changes bend smoothly instead of jumping.
      _from = _basePose(_time.value);
      _to = FacePose.of(widget.mood);
      _morphStart = _time.value;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  FacePose _basePose(double t) {
    final u = ((t - _morphStart) / _morphSeconds).clamp(0.0, 1.0);
    return FacePose.lerp(_from, _to, Curves.easeOutCubic.transform(u));
  }

  FacePose _framePose(double t) {
    var pose = _idle(_basePose(t), widget.mood, t);

    if (_blinksNaturally(widget.mood)) {
      if (t >= _nextBlinkAt) {
        _blinkStart = t;
        _nextBlinkAt = t + 2.5 + _random.nextDouble() * 3.0;
      }
      const blinkSeconds = 0.22;
      final b = (t - _blinkStart) / blinkSeconds;
      if (b >= 0 && b <= 1) {
        final lid = 1.0 - 0.92 * math.sin(math.pi * b);
        pose = pose.copyWith(
          left: pose.left.copyWith(squash: pose.left.squash * lid),
          right: pose.right.copyWith(squash: pose.right.squash * lid),
        );
      }
    }
    return pose;
  }

  bool _blinksNaturally(VisorMood mood) => switch (mood) {
        VisorMood.sleepy || VisorMood.lowBattery || VisorMood.love => false,
        _ => true,
      };

  /// Mood-specific micro-motion. Amplitudes are small on purpose — the
  /// face should feel alive, not busy.
  FacePose _idle(FacePose pose, VisorMood mood, double t) {
    switch (mood) {
      case VisorMood.neutral:
        return pose; // Blink alone carries the resting face.
      case VisorMood.curious:
        final look = Offset(
          0.30 + 0.14 * math.sin(t * 0.9),
          -0.18 + 0.10 * math.sin(t * 0.6 + 1.3),
        );
        return pose.copyWith(
          left: pose.left.copyWith(pupilOffset: look),
          right: pose.right.copyWith(pupilOffset: look),
        );
      case VisorMood.happy:
        final bob = Offset(0, 0.05 * math.sin(t * 3.2));
        return _offsetBoth(pose, bob);
      case VisorMood.delighted:
        final rays = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * 6.0));
        final bob = Offset(0, 0.08 * math.sin(t * 5.0));
        return pose.copyWith(
          left: pose.left
              .copyWith(rays: pose.left.rays * rays, offset: pose.left.offset + bob),
          right: pose.right
              .copyWith(rays: pose.right.rays * rays, offset: pose.right.offset + bob),
        );
      case VisorMood.love:
        // Double-thump heartbeat.
        final phase = t % 1.2;
        final beat = phase < 0.5
            ? math.sin(phase / 0.5 * math.pi * 2).abs() * 0.10
            : 0.0;
        return pose.copyWith(
          left: pose.left.copyWith(radius: pose.left.radius * (1 + beat)),
          right: pose.right.copyWith(radius: pose.right.radius * (1 + beat)),
        );
      case VisorMood.playful:
        final bob = Offset(0, 0.06 * math.sin(t * 4.0));
        return _offsetBoth(pose, bob);
      case VisorMood.startled:
        final pulse = 1 + 0.05 * math.sin(t * 10.0);
        return pose.copyWith(
          left: pose.left.copyWith(radius: pose.left.radius * pulse),
          right: pose.right.copyWith(radius: pose.right.radius * pulse),
        );
      case VisorMood.confused:
        return pose.copyWith(
          right:
              pose.right.copyWith(tilt: pose.right.tilt + 0.12 * math.sin(t * 2.6)),
          left: pose.left
              .copyWith(offset: pose.left.offset + Offset(0, 0.04 * math.sin(t * 2.6))),
        );
      case VisorMood.sleepy:
        // Slow heavy lids drifting lower.
        final lid = 0.75 + 0.25 * math.sin(t * 0.9);
        return pose.copyWith(
          left: pose.left.copyWith(squash: pose.left.squash * lid),
          right: pose.right.copyWith(squash: pose.right.squash * lid),
        );
      case VisorMood.sad:
        final droop = Offset(0, 0.06 + 0.04 * math.sin(t * 1.4));
        return _offsetBoth(pose, droop);
      case VisorMood.annoyed:
        final twitch = 0.04 * math.sin(t * 13.0);
        return pose.copyWith(
          left: pose.left.copyWith(tilt: pose.left.tilt + twitch),
          right: pose.right.copyWith(tilt: pose.right.tilt - twitch),
        );
      case VisorMood.proud:
        final twinkleL = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 5.0));
        final twinkleR = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 5.0 + 1.9));
        return pose.copyWith(
          left: pose.left.copyWith(sparkle: pose.left.sparkle * twinkleL),
          right: pose.right.copyWith(sparkle: pose.right.sparkle * twinkleR),
        );
      case VisorMood.yes:
        final nod = Offset(0, 0.12 * math.sin(t * 5.0));
        return _offsetBoth(pose, nod);
      case VisorMood.no:
        final shake = Offset(0.10 * math.sin(t * 7.0), 0);
        return _offsetBoth(pose, shake);
      case VisorMood.alarm:
        final pulse = 1 + 0.07 * math.sin(t * 12.0);
        final rays = 0.5 + 0.5 * (0.5 + 0.5 * math.sin(t * 12.0));
        return pose.copyWith(
          left: pose.left
              .copyWith(radius: pose.left.radius * pulse, rays: pose.left.rays * rays),
          right: pose.right
              .copyWith(radius: pose.right.radius * pulse, rays: pose.right.rays * rays),
        );
      case VisorMood.lowBattery:
        // Long exhausted blinks; the battery icon flickers.
        final lid = 0.45 + 0.55 * math.sin(t * 1.1).abs();
        final flicker = (t % 1.0) < 0.55 ? 1.0 : 0.5;
        return pose.copyWith(
          left: pose.left.copyWith(squash: pose.left.squash * lid),
          right: pose.right.copyWith(squash: pose.right.squash * lid),
          battery: pose.battery * flicker,
        );
    }
  }

  FacePose _offsetBoth(FacePose pose, Offset delta) {
    return pose.copyWith(
      left: pose.left.copyWith(offset: pose.left.offset + delta),
      right: pose.right.copyWith(offset: pose.right.offset + delta),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The bezel depicts the bot's OLED hardware: always black, in both
    // themes, like the physical device.
    return AspectRatio(
      aspectRatio: 2.0,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF000000),
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ValueListenableBuilder<double>(
          valueListenable: _time,
          builder: (context, t, _) {
            return CustomPaint(
              painter: FacePainter(pose: _framePose(t)),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}
