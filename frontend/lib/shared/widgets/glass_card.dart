import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// A glassmorphism card: a translucent container painted on top of a
/// `BackdropFilter` blur.
///
/// Implements requirement 10.2 — primary content containers are rendered as
/// glassmorphism cards with translucent backgrounds and blurred backdrops.
///
/// The card composes:
///   * A `BackdropFilter` with `ImageFilter.blur` applying gaussian blur to
///     whatever sits behind the card (e.g. the animated background).
///   * A translucent fill (default [kSurfaceGlass]) so that the blurred
///     backdrop shows through.
///   * A 1px hairline border using a low-alpha white, evoking frosted glass.
///
/// The blur is clipped to a rounded rectangle so the blurred region matches
/// the card silhouette.
///
/// Example:
/// ```dart
/// GlassCard(
///   padding: const EdgeInsets.all(16),
///   child: Text('Hello'),
/// )
/// ```
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.blurSigma = 18.0,
    this.backgroundColor = kSurfaceGlass,
    this.borderColor = const Color(0x33FFFFFF),
    this.borderWidth = 1.0,
    this.width,
    this.height,
  });

  /// Content rendered inside the glass surface.
  final Widget child;

  /// Inner padding around [child].
  final EdgeInsetsGeometry padding;

  /// Outer margin around the card.
  final EdgeInsetsGeometry margin;

  /// Corner radius for both the clip and the border.
  final BorderRadius borderRadius;

  /// Gaussian blur sigma applied to the backdrop. Larger values produce a
  /// softer frosted effect.
  final double blurSigma;

  /// Translucent fill color painted over the blurred backdrop.
  final Color backgroundColor;

  /// Hairline border color. Defaults to a low-alpha white for a frosted edge.
  final Color borderColor;

  /// Hairline border width.
  final double borderWidth;

  /// Optional explicit width.
  final double? width;

  /// Optional explicit height.
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            width: width,
            height: height,
            padding: padding,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: borderRadius,
              border: Border.all(color: borderColor, width: borderWidth),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
