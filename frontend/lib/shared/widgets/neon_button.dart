import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// An outlined button with a neon glow.
///
/// Implements requirement 10.3 — neon accent colors (cyan, purple, pink)
/// applied to interactive elements. Used for primary CTAs across the app.
///
/// Visual recipe:
///   * A 1.5px outline drawn from a neon accent (default [kNeonCyan]).
///   * A soft glow created via two `BoxShadow`s on the same color: a tight
///     inner shadow and a wider ambient shadow.
///   * Translucent fill that lifts on press and disabled state.
///   * Foreground (icon + label) colored by the same accent so the button
///     reads as glowing-on-glass.
///
/// [onPressed] may be null to disable the button (Material conventions).
/// When [isLoading] is true a small `CircularProgressIndicator` replaces the
/// label and presses are ignored.
class NeonButton extends StatelessWidget {
  const NeonButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = kNeonCyan,
    this.isLoading = false,
    this.minimumSize = const Size(120, 48),
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.padding =
        const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
  });

  /// The visible button text.
  final String label;

  /// Tap callback. Pass `null` to render the button in its disabled state.
  final VoidCallback? onPressed;

  /// Optional leading icon, rendered to the left of [label].
  final IconData? icon;

  /// Neon accent driving the outline, glow, and foreground.
  final Color color;

  /// When true, replaces the label with a spinner and ignores presses.
  final bool isLoading;

  /// Minimum button size.
  final Size minimumSize;

  /// Corner radius of the outline and ripple.
  final BorderRadius borderRadius;

  /// Inner padding.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null && !isLoading;
    final Color outline = enabled ? color : color.withValues(alpha: 0.4);
    final Color foreground = enabled ? color : color.withValues(alpha: 0.5);

    final Widget content = isLoading
        ? SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(foreground),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: enabled
            ? <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: 16,
                  spreadRadius: 0.5,
                ),
                BoxShadow(
                  color: color.withValues(alpha: 0.18),
                  blurRadius: 32,
                  spreadRadius: 4,
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          minimumSize: minimumSize,
          padding: padding,
          shape: RoundedRectangleBorder(borderRadius: borderRadius),
          side: BorderSide(color: outline, width: 1.5),
          backgroundColor: color.withValues(alpha: 0.08),
          foregroundColor: foreground,
        ),
        child: content,
      ),
    );
  }
}
