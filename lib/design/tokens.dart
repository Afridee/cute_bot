// Nothing design tokens — exact values from the design-system skill.
// Dark and light are both authored; neither is derived from the other.

import 'package:flutter/material.dart';

abstract final class CuteBotFonts {
  static const doto = 'Doto';
  static const grotesk = 'Space Grotesk';
  static const mono = 'Space Mono';
}

abstract final class CuteBotSpace {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
  static const xxxl = 64.0;
  static const xxxxl = 96.0;
}

/// Shared across modes: accent, status, motion.
abstract final class CuteBotSignal {
  static const accent = Color(0xFFD71921);
  static const accentSubtle = Color(0x26D71921);
  static const success = Color(0xFF4A9E5C);
  static const warning = Color(0xFFD4A843);
  static const error = Color(0xFFD71921);

  static const durationMicro = Duration(milliseconds: 200);
  static const durationTransition = Duration(milliseconds: 350);
  static const Curve curve = Curves.ease;
}

final class CuteBotColors {
  const CuteBotColors({
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.borderVisible,
    required this.textDisabled,
    required this.textSecondary,
    required this.textPrimary,
    required this.textDisplay,
    required this.interactive,
  });

  final Color canvas;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color borderVisible;
  final Color textDisabled;
  final Color textSecondary;
  final Color textPrimary;
  final Color textDisplay;
  final Color interactive;

  static const dark = CuteBotColors(
    canvas: Color(0xFF000000),
    surface: Color(0xFF111111),
    surfaceRaised: Color(0xFF1A1A1A),
    border: Color(0xFF222222),
    borderVisible: Color(0xFF333333),
    textDisabled: Color(0xFF666666),
    textSecondary: Color(0xFF999999),
    textPrimary: Color(0xFFE8E8E8),
    textDisplay: Color(0xFFFFFFFF),
    interactive: Color(0xFF5B9BF6),
  );

  static const light = CuteBotColors(
    canvas: Color(0xFFF5F5F5),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF0F0F0),
    border: Color(0xFFE8E8E8),
    borderVisible: Color(0xFFCCCCCC),
    textDisabled: Color(0xFF999999),
    textSecondary: Color(0xFF666666),
    textPrimary: Color(0xFF1A1A1A),
    textDisplay: Color(0xFF000000),
    interactive: Color(0xFF007AFF),
  );
}

/// Doto hero type: 36px+ only, round-dot axis, never body.
const List<FontVariation> kDotoVariations = [
  FontVariation('ROND', 100),
  FontVariation('wght', 400),
];

final class CuteBotType {
  const CuteBotType(this.colors);
  final CuteBotColors colors;

  TextStyle get displayXl => _doto(72, 1.0, -0.03);
  TextStyle get displayLg => _doto(48, 1.05, -0.02);
  TextStyle get displayMd => _doto(36, 1.1, -0.02);

  TextStyle get heading => _grotesk(24, 1.2, -0.24, FontWeight.w400);
  TextStyle get subheading => _grotesk(18, 1.3, 0, FontWeight.w400);
  TextStyle get body => _grotesk(16, 1.5, 0, FontWeight.w400);
  TextStyle get bodySm => _grotesk(14, 1.5, 0.14, FontWeight.w300);

  TextStyle get caption => _mono(12, 1.4, 0.48, colors.textSecondary);
  TextStyle get label => _mono(11, 1.2, 0.88, colors.textSecondary);
  TextStyle get button => _mono(13, 1.2, 0.78, colors.textPrimary);
  TextStyle get data => _mono(16, 1.3, 0, colors.textPrimary);

  TextStyle _doto(double size, double height, double trackingEm) => TextStyle(
        fontFamily: CuteBotFonts.doto,
        fontSize: size,
        height: height,
        letterSpacing: trackingEm * size,
        fontWeight: FontWeight.w400,
        color: colors.textDisplay,
        fontVariations: kDotoVariations,
      );

  TextStyle _grotesk(
    double size,
    double height,
    double letterSpacing,
    FontWeight weight,
  ) =>
      TextStyle(
        fontFamily: CuteBotFonts.grotesk,
        fontSize: size,
        height: height,
        letterSpacing: letterSpacing,
        fontWeight: weight,
        color: colors.textPrimary,
      );

  TextStyle _mono(
    double size,
    double height,
    double letterSpacing,
    Color color,
  ) =>
      TextStyle(
        fontFamily: CuteBotFonts.mono,
        fontSize: size,
        height: height,
        letterSpacing: letterSpacing,
        fontWeight: FontWeight.w400,
        color: color,
      );
}
