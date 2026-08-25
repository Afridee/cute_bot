import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

final class CuteBotTokens extends ThemeExtension<CuteBotTokens> {
  const CuteBotTokens({required this.colors, required this.typography});

  final CuteBotColors colors;
  final CuteBotType typography;

  static CuteBotTokens of(BuildContext context) {
    final tokens = Theme.of(context).extension<CuteBotTokens>();
    assert(tokens != null, 'CuteBotTokens missing from Theme');
    return tokens!;
  }

  static const dark = CuteBotTokens(
    colors: CuteBotColors.dark,
    typography: CuteBotType(CuteBotColors.dark),
  );

  static const light = CuteBotTokens(
    colors: CuteBotColors.light,
    typography: CuteBotType(CuteBotColors.light),
  );

  @override
  CuteBotTokens copyWith({CuteBotColors? colors, CuteBotType? typography}) {
    return CuteBotTokens(
      colors: colors ?? this.colors,
      typography: typography ?? this.typography,
    );
  }

  @override
  CuteBotTokens lerp(ThemeExtension<CuteBotTokens>? other, double t) {
    if (other is! CuteBotTokens) return this;
    return t < 0.5 ? this : other;
  }
}

abstract final class CuteBotTheme {
  static ThemeData get dark => _build(CuteBotTokens.dark, Brightness.dark);
  static ThemeData get light => _build(CuteBotTokens.light, Brightness.light);

  static ThemeData _build(CuteBotTokens tokens, Brightness brightness) {
    final c = tokens.colors;
    final type = tokens.typography;
    final overlay = brightness == Brightness.dark
        ? SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: c.canvas,
            systemNavigationBarIconBrightness: Brightness.light,
          )
        : SystemUiOverlayStyle.dark.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: c.canvas,
            systemNavigationBarIconBrightness: Brightness.dark,
          );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: c.canvas,
      canvasColor: c.canvas,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      splashColor: Colors.transparent,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.textDisplay,
        onPrimary: c.canvas,
        secondary: c.surfaceRaised,
        onSecondary: c.textPrimary,
        error: CuteBotSignal.error,
        onError: c.textDisplay,
        surface: c.canvas,
        onSurface: c.textPrimary,
      ),
      textTheme: TextTheme(
        displayLarge: type.displayXl,
        displayMedium: type.displayLg,
        displaySmall: type.displayMd,
        headlineMedium: type.heading,
        titleLarge: type.heading,
        titleMedium: type.subheading,
        bodyLarge: type.body,
        bodyMedium: type.body,
        bodySmall: type.bodySm,
        labelLarge: type.button,
        labelSmall: type.label,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.canvas,
        foregroundColor: c.textDisplay,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: overlay,
        titleTextStyle: type.label.copyWith(color: c.textSecondary),
        iconTheme: IconThemeData(color: c.textPrimary, size: 20),
      ),
      dividerColor: c.border,
      dividerTheme: DividerThemeData(
        color: c.border,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: c.textPrimary, size: 20),
      extensions: [tokens],
    );
  }
}

extension CuteBotThemeContext on BuildContext {
  CuteBotTokens get nd => CuteBotTokens.of(this);
}
