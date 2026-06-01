/// Widget tests for [SetGoalScreen] (task 10.3).
///
/// Pumps the screen wrapped in a [ProviderScope] with [profileProvider]
/// overridden to a [_FakeProfileNotifier] that records `patch()` calls,
/// so we can assert both the inline error UI and Property 6's "no HTTP
/// request when validation fails" guarantee at the widget layer.
///
/// The full property-based coverage of the validator lives in task
/// 10.4 (`frontend/test/property/set_goal_validation_test.dart`).
///
/// **Validates: Requirements 3.3, 3.4, 3.5**
library;

import 'package:devgrowth_ai/features/onboarding/domain/profile.dart';
import 'package:devgrowth_ai/features/onboarding/presentation/providers.dart';
import 'package:devgrowth_ai/features/onboarding/presentation/set_goal_screen.dart';
import 'package:devgrowth_ai/shared/widgets/animated_background.dart';
import 'package:devgrowth_ai/shared/widgets/gradient_text.dart';
import 'package:devgrowth_ai/shared/widgets/neon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [ProfileNotifier] stand-in that records every `patch()` call and
/// hands back a synthetic [Profile] without touching Dio or Supabase.
///
/// We override [ProfileNotifier] specifically (rather than swapping
/// the whole provider type) so the override slot in [profileProvider]
/// continues to type-check.
class _FakeProfileNotifier extends ProfileNotifier {
  _FakeProfileNotifier();

  /// Records the [ProfilePatch] passed to every successful or failing
  /// `patch()` call, in order. Tests assert against this directly.
  final List<ProfilePatch> patchCalls = <ProfilePatch>[];

  /// The profile we hand back to widgets that watch the provider.
  /// URLs are pre-set so the only missing onboarding field is `goal`,
  /// matching the state in which the user actually reaches `/goal`.
  static final Profile _seed = Profile(
    id: 'fake-uid',
    email: 'tester@example.com',
    githubUrl: 'https://github.com/alice',
    linkedinUrl: 'https://www.linkedin.com/in/alice',
    createdAt: DateTime.utc(2024, 1, 2, 3, 4, 5),
  );

  @override
  Future<Profile> build() async => _seed;

  @override
  Future<Profile> patch(ProfilePatch patch) async {
    patchCalls.add(patch);
    final Profile updated = _seed.copyWith(
      githubUrl: patch.githubUrl,
      linkedinUrl: patch.linkedinUrl,
      goal: patch.goal,
    );
    state = AsyncData<Profile>(updated);
    return updated;
  }
}

/// Pumps [SetGoalScreen] inside a [ProviderScope] where
/// [profileProvider] is overridden to [notifier]. We wrap the screen in
/// a plain [MaterialApp] so [ScaffoldMessenger] is available for
/// failure snackbars.
Future<void> _pumpScreen(
  WidgetTester tester, {
  required _FakeProfileNotifier notifier,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileProvider.overrideWith(() => notifier),
      ],
      child: const MaterialApp(
        home: SetGoalScreen(),
      ),
    ),
  );
  // Let the AsyncNotifier's build() future resolve and drain the
  // start-delay `Future.delayed` timers that `flutter_animate` (used
  // by [AnimatedBackground]) schedules per orb. Pumping past the
  // longest possible delay (~2s) converts them into ticker-driven
  // animations, which the test framework cleans up on dispose, so
  // the "no pending Timers" invariant passes at tear-down.
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  group('SetGoalScreen', () {
    testWidgets(
      'renders heading, animated background, text field, and neon button',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();
        await _pumpScreen(tester, notifier: notifier);

        // Heading uses the shared GradientText widget (Requirement 10.4).
        expect(find.byType(GradientText), findsOneWidget);
        expect(find.text('Set your goal'), findsOneWidget);

        // Animated background, text field, and neon button.
        expect(find.byType(AnimatedBackground), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.byType(NeonButton), findsOneWidget);
        expect(find.text('Save goal'), findsOneWidget);

        // Counter starts at 0 / 500.
        expect(find.text('0 / 500'), findsOneWidget);
      },
    );

    testWidgets(
      'empty submit shows inline error and does NOT call patch() '
      '(Property 6)',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();
        await _pumpScreen(tester, notifier: notifier);

        await tester.tap(find.byType(NeonButton));
        await tester.pump();

        expect(find.text('Please enter a career goal.'), findsOneWidget);
        expect(
          notifier.patchCalls,
          isEmpty,
          reason: 'Empty submit must not issue PATCH /profile/me',
        );
      },
    );

    testWidgets(
      '501-char submit shows inline error and does NOT call patch() '
      '(Property 6)',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();
        await _pumpScreen(tester, notifier: notifier);

        final String tooLong = 'a' * 501;
        await tester.enterText(find.byType(TextField), tooLong);
        await tester.pump();
        await tester.tap(find.byType(NeonButton));
        await tester.pump();

        expect(
          find.text('Goal must be 500 characters or fewer.'),
          findsOneWidget,
        );
        expect(
          notifier.patchCalls,
          isEmpty,
          reason: 'Oversize submit must not issue PATCH /profile/me',
        );
        // Counter shows the over-limit count.
        expect(find.text('501 / 500'), findsOneWidget);
      },
    );

    testWidgets(
      'whitespace-only submit shows inline error and does NOT call '
      'patch() (Property 6)',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();
        await _pumpScreen(tester, notifier: notifier);

        await tester.enterText(find.byType(TextField), '     ');
        await tester.pump();
        await tester.tap(find.byType(NeonButton));
        await tester.pump();

        expect(find.text('Goal cannot be only whitespace.'), findsOneWidget);
        expect(notifier.patchCalls, isEmpty);
      },
    );

    testWidgets(
      'valid submit calls patch() with the trimmed goal',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();
        await _pumpScreen(tester, notifier: notifier);

        await tester.enterText(
          find.byType(TextField),
          '  Become a Senior Backend Engineer  ',
        );
        await tester.pump();
        await tester.tap(find.byType(NeonButton));
        // Drain microtasks so the awaited patch() resolves.
        await tester.pump();
        await tester.pump();

        expect(notifier.patchCalls, hasLength(1));
        final ProfilePatch sent = notifier.patchCalls.single;
        expect(sent.goal, 'Become a Senior Backend Engineer');
        // The screen owns only the goal step; URLs must not be touched.
        expect(sent.githubUrl, isNull);
        expect(sent.linkedinUrl, isNull);
        expect(
          sent.toJson(),
          equals(<String, dynamic>{
            'goal': 'Become a Senior Backend Engineer',
          }),
        );
      },
    );
  });
}
