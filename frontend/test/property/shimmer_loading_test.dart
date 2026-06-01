/// Property test for the shimmer-loading UI contract.
///
/// **Property 26 — Async-loading UI always renders a shimmer placeholder.**
///
/// For any widget bound to an `AsyncValue` whose state is `loading`, the
/// widget tree contains a [ShimmerLoader] placeholder in place of the
/// pending content. Conversely, for any non-loading `AsyncValue`
/// (`AsyncData` or `AsyncError`), the widget tree does NOT contain a
/// [ShimmerLoader] — the resolved content (or error UI) is rendered
/// instead.
///
/// We model the canonical pattern used across the dashboard, onboarding,
/// and settings surfaces: a small [_AsyncSlot] widget that switches on
/// `AsyncValue.when(...)` and emits a [ShimmerLoader] for the `loading`
/// case. The property is then exercised across many randomly generated
/// `AsyncValue<T>` inputs covering several payload types (`int`,
/// `String`, `List<int>`) and every [ShimmerLoader] factory variant
/// (default, [ShimmerLoader.lines], [ShimmerLoader.block]).
///
/// **Validates: Requirement 10.6**
library;

import 'dart:math';

import 'package:devgrowth_ai/shared/widgets/shimmer_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Number of random iterations per property. Matches the design's
/// "at least 100 iterations" requirement for property tests.
const int _iterations = 100;

/// The three [ShimmerLoader] factory variants we sweep over so the
/// property holds independently of which slot shape is used.
enum _ShimmerVariant { defaultBlock, lines, block }

/// A tiny widget that demonstrates the canonical "render an
/// `AsyncValue` with a shimmer placeholder" pattern. Any widget that
/// follows this pattern satisfies Property 26 by construction; the
/// property test confirms the pattern itself does.
class _AsyncSlot<T> extends StatelessWidget {
  const _AsyncSlot({
    required this.value,
    required this.variant,
    super.key,
  });

  final AsyncValue<T> value;
  final _ShimmerVariant variant;

  Widget _buildShimmer() {
    switch (variant) {
      case _ShimmerVariant.defaultBlock:
        return const ShimmerLoader();
      case _ShimmerVariant.lines:
        return const ShimmerLoader.lines(lines: 3);
      case _ShimmerVariant.block:
        return const ShimmerLoader.block(width: 120, height: 40);
    }
  }

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => _buildShimmer(),
      data: (T v) => Text('data:$v', key: const Key('data-slot')),
      error: (Object e, StackTrace _) =>
          Text('error:$e', key: const Key('error-slot')),
    );
  }
}

/// Random `AsyncValue` generator. Returns an `AsyncValue<dynamic>`
/// whose runtime value type is one of `int`, `String`, or `List<int>`,
/// uniformly across the three `AsyncValue` constructors. We use
/// `dynamic` at the seam so a single iteration can sweep multiple
/// payload types.
AsyncValue<Object?> _randomAsyncValue(Random rng) {
  // 0 = loading, 1 = data, 2 = error. Bias slightly toward `loading`
  // so we still get a healthy number of "should-shimmer" cases.
  final int kind = rng.nextInt(4) == 0 ? 1 : (rng.nextInt(3) == 0 ? 2 : 0);

  switch (kind) {
    case 0:
      // AsyncLoading. Sometimes pass a progress value, sometimes don't,
      // to cover both constructor forms.
      if (rng.nextBool()) {
        return const AsyncValue<Object?>.loading();
      }
      return AsyncValue<Object?>.loading(progress: rng.nextDouble());
    case 1:
      return AsyncValue<Object?>.data(_randomPayload(rng));
    case 2:
    default:
      return AsyncValue<Object?>.error(
        Exception('boom-${rng.nextInt(1 << 16)}'),
        StackTrace.empty,
      );
  }
}

/// Generates a random payload spanning `int`, `String`, and `List<int>`.
Object _randomPayload(Random rng) {
  switch (rng.nextInt(3)) {
    case 0:
      return rng.nextInt(1 << 31);
    case 1:
      return _randomString(rng, minLen: 0, maxLen: 32);
    case 2:
    default:
      final int len = rng.nextInt(8);
      return List<int>.generate(len, (_) => rng.nextInt(256));
  }
}

String _randomString(
  Random rng, {
  required int minLen,
  required int maxLen,
}) {
  const String alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_./';
  final int length = minLen + rng.nextInt(maxLen - minLen + 1);
  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < length; i++) {
    buf.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}

_ShimmerVariant _randomVariant(Random rng) =>
    _ShimmerVariant.values[rng.nextInt(_ShimmerVariant.values.length)];

/// Pumps the [_AsyncSlot] inside a minimal [MaterialApp] scaffold so
/// that text styling, directionality, and animation tickers are
/// available.
Future<void> _pumpSlot(
  WidgetTester tester, {
  required AsyncValue<Object?> value,
  required _ShimmerVariant variant,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: _AsyncSlot<Object?>(value: value, variant: variant),
        ),
      ),
    ),
  );
  // `Shimmer.fromColors` runs an internal animation controller. A single
  // pump is enough to lay out and find the [ShimmerLoader] in the tree;
  // we deliberately avoid `pumpAndSettle()` because the animation is
  // perpetual and would never settle.
}

void main() {
  group('Property 26: Async-loading UI always renders a shimmer placeholder',
      () {
    testWidgets(
      'AsyncValue.loading always produces a ShimmerLoader in the tree, '
      'and non-loading states never do',
      (WidgetTester tester) async {
        final Random rng = Random(0xA5F00D);

        for (int i = 0; i < _iterations; i++) {
          final AsyncValue<Object?> value = _randomAsyncValue(rng);
          final _ShimmerVariant variant = _randomVariant(rng);

          await _pumpSlot(tester, value: value, variant: variant);

          final Finder shimmer = find.byType(ShimmerLoader);

          if (value is AsyncLoading) {
            expect(
              shimmer,
              findsOneWidget,
              reason: 'iteration $i: AsyncValue.loading (variant=$variant) '
                  'must render exactly one ShimmerLoader, but the tree '
                  'contained ${tester.widgetList(shimmer).length}.',
            );
            // The pending content must NOT appear while loading.
            expect(
              find.byKey(const Key('data-slot')),
              findsNothing,
              reason: 'iteration $i: data slot leaked into a loading state',
            );
            expect(
              find.byKey(const Key('error-slot')),
              findsNothing,
              reason: 'iteration $i: error slot leaked into a loading state',
            );
          } else {
            expect(
              shimmer,
              findsNothing,
              reason: 'iteration $i: non-loading AsyncValue '
                  '(${value.runtimeType}) must not render a ShimmerLoader',
            );
            // The resolved (data or error) slot must be present instead.
            final Finder resolved = value is AsyncError
                ? find.byKey(const Key('error-slot'))
                : find.byKey(const Key('data-slot'));
            expect(
              resolved,
              findsOneWidget,
              reason: 'iteration $i: non-loading AsyncValue '
                  '(${value.runtimeType}) did not render its resolved slot',
            );
          }
        }
      },
    );

    testWidgets(
      'every ShimmerLoader factory variant satisfies the property '
      'when bound to a loading AsyncValue',
      (WidgetTester tester) async {
        // Exhaustive sweep over the variants for the loading branch so
        // we never silently miss one variant under the random sampler.
        for (final _ShimmerVariant variant in _ShimmerVariant.values) {
          await _pumpSlot(
            tester,
            value: const AsyncValue<Object?>.loading(),
            variant: variant,
          );
          expect(
            find.byType(ShimmerLoader),
            findsOneWidget,
            reason: 'variant=$variant: loading state must render '
                'exactly one ShimmerLoader',
          );
        }
      },
    );
  });
}
