import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Renders [text] with a horizontal gradient fill spanning the neon palette.
///
/// Implements requirement 10.4 — top-level page headings carry a gradient fill
/// spanning at least two of the neon accent colors.
///
/// Internals:
///   * Wraps a [Text] in a [ShaderMask] whose shader is built from
///     [kNeonGradient] (cyan → purple → pink, three accents).
///   * The base [Text] color must be white for the shader to take effect;
///     the [TextTheme] in `core/theme.dart` already uses white for display
///     and headline styles, but we also force `color: Colors.white` on the
///     resolved style as a defense-in-depth.
///   * `BlendMode.srcIn` replaces the source (text glyphs) with the gradient,
///     preserving text geometry and anti-aliasing.
///
/// The widget intentionally stays close to a `Text` to remain a drop-in
/// replacement in headings.
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    this.style,
    this.gradient = kNeonGradient,
    this.textAlign,
    this.textDirection,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.semanticsLabel,
  });

  /// The string to render.
  final String text;

  /// Optional text style. Any color is overridden to white so the shader
  /// applies cleanly.
  final TextStyle? style;

  /// Gradient that fills the text glyphs. Defaults to the neon palette.
  final Gradient gradient;

  /// Forwarded to the underlying [Text].
  final TextAlign? textAlign;

  /// Forwarded to the underlying [Text].
  final TextDirection? textDirection;

  /// Forwarded to the underlying [Text].
  final int? maxLines;

  /// Forwarded to the underlying [Text].
  final TextOverflow? overflow;

  /// Forwarded to the underlying [Text].
  final bool? softWrap;

  /// Forwarded to the underlying [Text]. Useful so screen readers still
  /// announce the original string.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final TextStyle effectiveStyle = (style ?? const TextStyle()).copyWith(
      color: Colors.white,
    );

    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) => gradient.createShader(bounds),
      child: Text(
        text,
        style: effectiveStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        maxLines: maxLines,
        overflow: overflow,
        softWrap: softWrap,
        semanticsLabel: semanticsLabel,
      ),
    );
  }
}
