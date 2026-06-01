import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/theme.dart';

/// A neon-tinted animated background used on the login, onboarding, and
/// dashboard screens.
///
/// Implements requirement 10.5 — "render an animated background on the
/// login, onboarding, and dashboard screens". The widget paints a deep
/// black base, lays down a few large blurred neon "orbs" drawn from the
/// app palette ([kNeonCyan], [kNeonPurple], [kNeonPink]), and animates
/// them with [flutter_animate] so the surface reads as alive without
/// pulling focus from the foreground content.
///
/// Composition:
///   * The base layer is a [Container] filled with [kBgDeep].
///   * Each orb is a soft, blurred circle painted with [BackdropFilter]-
///     free `BoxShadow` (so it works on Web and Mobile without GPU
///     filter chains), positioned with a random-but-stable offset.
///   * Orbs drift on a slow, staggered loop (`moveX` / `moveY` between
///     ~6–12 seconds) and gently scale to evoke breathing.
///
/// The widget exposes a [child] slot so callers can wrap their screen
/// content directly:
///
/// ```dart
/// AnimatedBackground(
///   child: Scaffold(
///     backgroundColor: Colors.transparent,
///     body: ...,
///   ),
/// )
/// ```
///
/// `intensity` controls overall opacity of the orbs; pass a lower value
/// on screens with dense foreground content.
class AnimatedBackground extends StatelessWidget {
  const AnimatedBackground({
    super.key,
    required this.child,
    this.intensity = 1.0,
    this.seed = 1337,
  }) : assert(intensity >= 0.0 && intensity <= 1.0,
            'intensity must be in [0, 1]');

  /// Foreground content rendered on top of the animated background.
  final Widget child;

  /// Overall opacity multiplier on the orbs, in `[0.0, 1.0]`.
  ///
  /// `1.0` is the default brand intensity used on the login/onboarding
  /// screens; the dashboard typically passes `0.6` so analysis cards
  /// stay legible.
  final double intensity;

  /// Seed for the deterministic orb layout. Kept as a parameter so
  /// widget tests can pin the layout across runs.
  final int seed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 1. Solid dark base.
        const ColoredBox(color: kBgDeep),
        // 2. Animated neon orbs.
        Positioned.fill(
          child: IgnorePointer(
            child: _OrbField(intensity: intensity, seed: seed),
          ),
        ),
        // 3. Foreground content.
        child,
      ],
    );
  }
}

/// Internal: paints and animates a small, fixed set of neon orbs.
///
/// The set is intentionally small (5 orbs) so the cost stays predictable
/// across Web and Mobile. Each orb is a gradient-filled circle wrapped
/// in `flutter_animate` effects: a slow `moveX`/`moveY` loop plus a
/// subtle scale "breath".
class _OrbField extends StatelessWidget {
  const _OrbField({required this.intensity, required this.seed});

  final double intensity;
  final int seed;

  static const List<Color> _palette = <Color>[
    kNeonCyan,
    kNeonPurple,
    kNeonPink,
  ];

  // Five orbs is enough for full-screen coverage with overlap, and
  // small enough to keep frame budgets cheap.
  static const int _orbCount = 5;

  @override
  Widget build(BuildContext context) {
    final Random rng = Random(seed);

    final List<_OrbSpec> specs = List<_OrbSpec>.generate(_orbCount, (int i) {
      // Anchor each orb in a different region so they don't all clump
      // at the centre. Dx/dy are unit-square fractions [0, 1].
      final double dx = (i / _orbCount) + rng.nextDouble() * (1 / _orbCount);
      final double dy = rng.nextDouble();
      final Color color = _palette[i % _palette.length];

      return _OrbSpec(
        color: color,
        // Fractional position inside the bounding box.
        anchorDx: dx.clamp(0.05, 0.95),
        anchorDy: dy.clamp(0.05, 0.95),
        // Diameter in logical pixels. Mix of large + small for depth.
        diameter: 220.0 + rng.nextDouble() * 220.0,
        // Per-orb drift offsets (in logical pixels) and durations.
        driftDx: 40.0 + rng.nextDouble() * 60.0,
        driftDy: 40.0 + rng.nextDouble() * 60.0,
        moveDuration:
            Duration(milliseconds: 6000 + rng.nextInt(6000)),
        scaleDuration:
            Duration(milliseconds: 4000 + rng.nextInt(4000)),
        startDelay: Duration(milliseconds: rng.nextInt(2000)),
      );
    });

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double height = constraints.maxHeight;

        return Stack(
          children: <Widget>[
            for (final _OrbSpec spec in specs)
              Positioned(
                left: spec.anchorDx * width - spec.diameter / 2,
                top: spec.anchorDy * height - spec.diameter / 2,
                width: spec.diameter,
                height: spec.diameter,
                child: _Orb(spec: spec, intensity: intensity),
              ),
          ],
        );
      },
    );
  }
}

/// Layout + animation parameters for a single orb.
class _OrbSpec {
  const _OrbSpec({
    required this.color,
    required this.anchorDx,
    required this.anchorDy,
    required this.diameter,
    required this.driftDx,
    required this.driftDy,
    required this.moveDuration,
    required this.scaleDuration,
    required this.startDelay,
  });

  final Color color;
  final double anchorDx;
  final double anchorDy;
  final double diameter;
  final double driftDx;
  final double driftDy;
  final Duration moveDuration;
  final Duration scaleDuration;
  final Duration startDelay;
}

/// A single soft neon orb with `flutter_animate` drift + breathing.
class _Orb extends StatelessWidget {
  const _Orb({required this.spec, required this.intensity});

  final _OrbSpec spec;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    // The orb itself: a radial-gradient circle that fades the neon
    // colour out to fully transparent at the rim, so multiple orbs
    // composite as a soft additive glow.
    final Widget orb = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[
            // Centre ~35% intensity at full opacity.
            spec.color.withValues(alpha: 0.35 * intensity),
            spec.color.withValues(alpha: 0.0),
          ],
          stops: const <double>[0.0, 1.0],
        ),
      ),
    );

    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: orb
          .animate(
            onPlay: (AnimationController c) => c.repeat(reverse: true),
            delay: spec.startDelay,
          )
          .moveX(
            begin: -spec.driftDx,
            end: spec.driftDx,
            duration: spec.moveDuration,
            curve: Curves.easeInOut,
          )
          .moveY(
            begin: -spec.driftDy,
            end: spec.driftDy,
            duration: spec.moveDuration,
            curve: Curves.easeInOut,
          )
          .scale(
            begin: const Offset(0.9, 0.9),
            end: const Offset(1.1, 1.1),
            duration: spec.scaleDuration,
            curve: Curves.easeInOut,
          ),
    );
  }
}
