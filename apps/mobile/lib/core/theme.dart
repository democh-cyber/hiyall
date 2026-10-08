import 'package:flutter/material.dart';

abstract final class VibeColors {
  static const ink = Color(0xff20231f);
  static const lime = Color(0xffd2f65a);
  static const cream = Color(0xfff7f8f2);
  static const lilac = Color(0xffd8c9fa);
  static const pink = Color(0xfff6bed4);
  static const mint = Color(0xffc4e8da);
  static const peach = Color(0xffffd1b5);
  static const success = Color(0xff246846);
  static const warning = Color(0xff8b5a14);
  static const error = Color(0xffb42335);
  static const info = Color(0xff564383);
}

ThemeData kairovaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: VibeColors.lime,
        brightness: brightness,
      ).copyWith(
        primary: dark ? VibeColors.lime : VibeColors.ink,
        onPrimary: dark ? VibeColors.ink : VibeColors.lime,
        primaryContainer: VibeColors.lime,
        onPrimaryContainer: VibeColors.ink,
        secondary: dark ? VibeColors.lilac : const Color(0xff675391),
        secondaryContainer: dark ? const Color(0xff39333f) : VibeColors.lilac,
        surface: dark ? const Color(0xff272b26) : Colors.white,
        onSurface: dark ? const Color(0xfff5f6ed) : VibeColors.ink,
        onSurfaceVariant: dark
            ? const Color(0xffc0c5b8)
            : const Color(0xff60665b),
        error: dark ? const Color(0xffffb4bf) : VibeColors.error,
        outlineVariant: dark
            ? const Color(0xff41463d)
            : const Color(0xffe4e7dd),
      );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Manrope',
    colorScheme: scheme,
  );
  final headings = base.textTheme.apply(fontFamily: 'SpaceGrotesk');
  return base.copyWith(
    scaffoldBackgroundColor: dark ? const Color(0xff191c18) : VibeColors.cream,
    textTheme: base.textTheme.copyWith(
      displayLarge: headings.displayLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -3,
      ),
      headlineLarge: headings.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.8,
      ),
      headlineMedium: headings.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
      ),
      headlineSmall: headings.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.7,
      ),
      titleLarge: headings.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
      titleMedium: headings.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.6),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.6),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeRadius.surface),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff20241f) : VibeColors.cream,
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VibeRadius.input),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VibeRadius.input),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(VibeRadius.input),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: VibeColors.lime,
        foregroundColor: VibeColors.ink,
        minimumSize: const Size(48, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        textStyle: const TextStyle(
          fontFamily: 'Manrope',
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeRadius.control),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: const TextStyle(
          fontFamily: 'Manrope',
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeRadius.control),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(
          fontFamily: 'Manrope',
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? VibeColors.ink : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? VibeColors.lime : null,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: VibeColors.ink,
      indicatorColor: VibeColors.lime,
      height: 76,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: 'Manrope',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: s.contains(WidgetState.selected)
              ? VibeColors.lime
              : const Color(0xffd0d5c8),
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 23,
          color: s.contains(WidgetState.selected)
              ? VibeColors.ink
              : const Color(0xffd0d5c8),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: VibeColors.ink,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontFamily: 'Manrope',
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeRadius.input),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
  );
}

abstract final class VibeSpacing {
  static const xs = 4.0, sm = 8.0, md = 16.0, lg = 24.0, xl = 32.0;
}

abstract final class VibeRadius {
  static const small = 8.0, input = 16.0, control = 18.0, surface = 28.0;
}

abstract final class VibeMotion {
  static Duration duration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);
}
