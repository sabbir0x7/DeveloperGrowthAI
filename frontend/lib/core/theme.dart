import 'package:flutter/material.dart';

/// Neon palette and dark theme for DevGrowth AI.
///
/// The app uses a single dark theme with neon accent colors (cyan, purple,
/// pink) over a deep, near-black background. Top-level page headings are
/// rendered with a horizontal gradient spanning the three accents using a
/// `ShaderMask` (see `shared/widgets/gradient_text.dart`).
///
/// This file exposes:
///   * Const palette colors: [kNeonCyan], [kNeonPurple], [kNeonPink],
///     [kBgDeep], [kSurfaceGlass].
///   * The const [kNeonGradient] used by gradient text/borders.
///   * [buildDarkTheme] returning a configured [ThemeData].
///
/// The theme is intentionally not mounted into `MaterialApp` here; the
/// app entrypoint wires it up.

// ---------------------------------------------------------------------------
// Neon palette
// ---------------------------------------------------------------------------

/// Neon cyan accent.
const Color kNeonCyan = Color(0xFF00E5FF);

/// Neon purple accent (also used as the seed color for [ColorScheme.fromSeed]).
const Color kNeonPurple = Color(0xFFB14EFF);

/// Neon pink accent.
const Color kNeonPink = Color(0xFFFF3D9A);

/// Deep, near-black background used as the scaffold background.
const Color kBgDeep = Color(0xFF06060C);

/// Translucent white surface used for glassmorphism cards (8% white).
const Color kSurfaceGlass = Color(0x14FFFFFF);

// ---------------------------------------------------------------------------
// Gradient
// ---------------------------------------------------------------------------

/// Horizontal neon gradient spanning the three accent colors, left to right.
///
/// Used by gradient text (`ShaderMask`) and gradient borders.
const LinearGradient kNeonGradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: <Color>[kNeonCyan, kNeonPurple, kNeonPink],
);

// ---------------------------------------------------------------------------
// Text theme
// ---------------------------------------------------------------------------

/// Text theme with bold display/headline styles suitable for gradient masking.
///
/// The colors are intentionally set to white; gradient masking is applied at
/// render time by `GradientText` via `ShaderMask`, which replaces the source
/// color with the gradient shader.
const TextTheme _kTextTheme = TextTheme(
  displayLarge: TextStyle(
    fontSize: 57,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.0,
    height: 1.1,
    color: Colors.white,
  ),
  displayMedium: TextStyle(
    fontSize: 45,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.5,
    height: 1.15,
    color: Colors.white,
  ),
  displaySmall: TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: Colors.white,
  ),
  headlineLarge: TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    height: 1.25,
    color: Colors.white,
  ),
  headlineMedium: TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: Colors.white,
  ),
  headlineSmall: TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: Colors.white,
  ),
  titleLarge: TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: Colors.white,
  ),
  titleMedium: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.15,
    color: Colors.white,
  ),
  titleSmall: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    color: Colors.white,
  ),
  bodyLarge: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: Colors.white,
  ),
  bodyMedium: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
    color: Colors.white70,
  ),
  bodySmall: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: Colors.white70,
  ),
  labelLarge: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: Colors.white,
  ),
  labelMedium: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: Colors.white,
  ),
  labelSmall: TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: Colors.white,
  ),
);

// ---------------------------------------------------------------------------
// Theme builder
// ---------------------------------------------------------------------------

/// Builds the dark, neon-accented [ThemeData] used across the app.
///
/// Starts from `ColorScheme.fromSeed` with [kNeonPurple] as the seed and
/// `Brightness.dark`, then overrides `primary`/`secondary`/`tertiary`/
/// `surface`/`background` with the explicit neon palette so that Material
/// components pick up the brand accents directly.
ThemeData buildDarkTheme() {
  final ColorScheme baseScheme = ColorScheme.fromSeed(
    seedColor: kNeonPurple,
    brightness: Brightness.dark,
  );

  final ColorScheme scheme = baseScheme.copyWith(
    primary: kNeonPurple,
    onPrimary: Colors.white,
    secondary: kNeonCyan,
    onSecondary: Colors.black,
    tertiary: kNeonPink,
    onTertiary: Colors.white,
    surface: kBgDeep,
    onSurface: Colors.white,
    // ignore: deprecated_member_use
    background: kBgDeep,
    // ignore: deprecated_member_use
    onBackground: Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBgDeep,
    canvasColor: kBgDeep,
    textTheme: _kTextTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      foregroundColor: Colors.white,
      centerTitle: false,
    ),
  );
}
