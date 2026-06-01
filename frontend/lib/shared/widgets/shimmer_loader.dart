import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/theme.dart';

/// A shimmer placeholder used in place of pending content while an
/// asynchronous load is in progress.
///
/// Implements requirement 10.6 — while async data is loading, the app
/// renders a shimmer placeholder instead of the pending content. The
/// widget is intentionally kept generic: any widget tree that maps from
/// `AsyncValue.loading` to a [ShimmerLoader] satisfies the property
/// "Async-loading UI always renders a shimmer placeholder" (Property 26).
///
/// Visual design:
///   * Base color is a low-alpha white (matches the dark, glassmorphism
///     surfaces used elsewhere in the app).
///   * Highlight color is a faint cyan tint drawn from the neon palette
///     (see [kNeonCyan]) so the shimmer reads as part of the brand
///     instead of generic gray.
///   * Each "line" or "block" is a rounded rectangle painted in the
///     base color; the [Shimmer.fromColors] gradient sweeps across them.
///
/// Two factory constructors cover the common slot shapes:
///
///   * [ShimmerLoader.lines] renders a stack of [lines] horizontal bars
///     of [lineHeight] separated by [gap]. Use this for text-heavy
///     placeholders such as the dashboard analysis copy.
///
///   * [ShimmerLoader.block] renders a single rounded rectangle of the
///     given [width] and [height]. Use this for image, card, or button
///     placeholders.
///
/// The default [ShimmerLoader] constructor renders a single block that
/// fills its parent (`double.infinity` width, [height] tall), which is
/// the most common slot shape inside a column of glass cards.
class ShimmerLoader extends StatelessWidget {
  /// Builds a single full-width shimmer block of [height].
  const ShimmerLoader({
    super.key,
    this.height = 16,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  })  : _kind = _ShimmerKind.block,
        _lines = 1,
        _lineHeight = 0,
        _gap = 0,
        _width = double.infinity;

  /// Builds a stack of [lines] shimmer bars separated by [gap]. The last
  /// line is rendered shorter (60% width) to evoke a paragraph end.
  const ShimmerLoader.lines({
    super.key,
    int lines = 3,
    double lineHeight = 12,
    double gap = 10,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  })  : assert(lines > 0, 'lines must be positive'),
        assert(lineHeight > 0, 'lineHeight must be positive'),
        assert(gap >= 0, 'gap must be non-negative'),
        _kind = _ShimmerKind.lines,
        _lines = lines,
        _lineHeight = lineHeight,
        _gap = gap,
        height = 0,
        _width = double.infinity;

  /// Builds a single shimmer rectangle of [width] x [height].
  const ShimmerLoader.block({
    super.key,
    required double width,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  })  : _kind = _ShimmerKind.block,
        _lines = 1,
        _lineHeight = 0,
        _gap = 0,
        _width = width;

  /// Height of the rendered placeholder when using the default or
  /// [ShimmerLoader.block] variants.
  final double height;

  /// Corner radius applied to every shimmer rectangle.
  final BorderRadius borderRadius;

  // Internal layout knobs, set by the named constructors.
  final _ShimmerKind _kind;
  final int _lines;
  final double _lineHeight;
  final double _gap;
  final double _width;

  // Palette for the shimmer gradient. Kept here (not in `theme.dart`) so
  // shimmer styling is co-located with its only consumer.
  static const Color _kBaseColor = Color(0x14FFFFFF); // 8% white
  static const Color _kHighlightColor = Color(0x3300E5FF); // 20% neon cyan

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: _kBaseColor,
      highlightColor: _kHighlightColor,
      period: const Duration(milliseconds: 1400),
      child: _buildChild(),
    );
  }

  Widget _buildChild() {
    switch (_kind) {
      case _ShimmerKind.block:
        return _shimmerBox(width: _width, height: height);
      case _ShimmerKind.lines:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < _lines; i++) ...<Widget>[
              if (i > 0) SizedBox(height: _gap),
              // Last line renders shorter to mimic a paragraph tail.
              if (i == _lines - 1 && _lines > 1)
                FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 0.6,
                  child: _shimmerBox(
                    width: double.infinity,
                    height: _lineHeight,
                  ),
                )
              else
                _shimmerBox(width: double.infinity, height: _lineHeight),
            ],
          ],
        );
    }
  }

  Widget _shimmerBox({required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _kBaseColor,
        borderRadius: borderRadius,
      ),
    );
  }
}

enum _ShimmerKind { block, lines }
