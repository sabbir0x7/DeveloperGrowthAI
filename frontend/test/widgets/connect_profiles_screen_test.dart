/// Widget tests for [ConnectProfilesScreen] (task 10.2).
///
/// Pumps the screen under a [ProviderScope] with [profileProvider]
/// overridden to a fake notifier that records every `patch()` call so
/// assertions can verify both the inline-validation contract
/// (Requirement 2.4 — non-HTTPS URLs are rejected client-side) and the
/// happy-path wire format (Requirement 3.2 — submit calls
/// `PATCH /profile/me`).
library;

import 'package:devgrowth_ai/features/onboarding/domain/profile.dart';
import 'package:devgrowth_ai/features/onboarding/presentation/connect_profiles_screen.dart';
import 'package:devgrowth_ai/features/onboarding/presentation/providers.dart';
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
  /// Empty onboarding fields by default so the guard would forward to
  /// `/connect` if it were running (we bypass the guard in tests).
  static final Profile _seed = Profile(
    id: 'fake-uid',
    email: 'tester@example.com',
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

/// Pumps [ConnectProfilesScreen] inside a [ProviderScope] where
/// [profileProvider] is overridden to [notifier]. Returns once the
/// initial frame is laid out. We wrap the screen in a plain
/// [MaterialApp] so [ScaffoldMessenger] is available for snackbars.
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
        home: ConnectProfilesScreen(),
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
  group('ConnectProfilesScreen', () {
    testWidgets(
      'renders heading, animated background, two URL fields, and the '
      'neon submit button',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();

        await _pumpScreen(tester, notifier: notifier);

        // Animated background is mounted as the screen backdrop
        // (Requirement 10.5).
        expect(find.byType(AnimatedBackground), findsOneWidget);

        // Heading uses the shared GradientText widget so the gradient
        // styling (Requirement 10.4) is inherited; we look it up by
        // key to avoid over-fitting to copy.
        expect(
          find.byKey(ConnectProfilesScreen.headingKey),
          findsOneWidget,
        );
        expect(find.byType(GradientText), findsAtLeastNWidgets(1));

        // Two URL fields by key.
        expect(
          find.byKey(ConnectProfilesScreen.githubFieldKey),
          findsOneWidget,
        );
        expect(
          find.byKey(ConnectProfilesScreen.linkedinFieldKey),
          findsOneWidget,
        );

        // The submit CTA is the shared NeonButton.
        expect(
          find.byKey(ConnectProfilesScreen.submitButtonKey),
          findsOneWidget,
        );
        expect(find.byType(NeonButton), findsOneWidget);
      },
    );

    testWidgets(
      'rejects non-HTTPS URLs inline and never calls patch() '
      '(Requirement 2.4)',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();

        await _pumpScreen(tester, notifier: notifier);

        // Enter an http:// URL into the GitHub field. The LinkedIn
        // field is left blank so submit must fail validation either
        // way; the property under test is that the github_url error
        // is raised.
        await tester.enterText(
          find.byKey(ConnectProfilesScreen.githubFieldKey),
          'http://github.com/insecure',
        );
        // Tap the submit button.
        await tester.tap(find.byKey(ConnectProfilesScreen.submitButtonKey));
        await tester.pump();

        // Inline error is rendered under the GitHub field (the message
        // produced by `validateHttpsUrl` for a non-https scheme).
        expect(
          find.text('URL must start with https://.'),
          findsOneWidget,
          reason: 'http:// input must surface an inline HTTPS-only error',
        );

        // patch() must NOT have been called.
        expect(
          notifier.patchCalls,
          isEmpty,
          reason:
              'Submit with a non-HTTPS URL must not call PATCH /profile/me',
        );
      },
    );

    testWidgets(
      'on submit with two valid HTTPS URLs, calls patch() with the '
      'correct ProfilePatch',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();

        await _pumpScreen(tester, notifier: notifier);

        const String github = 'https://github.com/alice';
        const String linkedin = 'https://www.linkedin.com/in/alice';

        await tester.enterText(
          find.byKey(ConnectProfilesScreen.githubFieldKey),
          github,
        );
        await tester.enterText(
          find.byKey(ConnectProfilesScreen.linkedinFieldKey),
          linkedin,
        );
        await tester.tap(find.byKey(ConnectProfilesScreen.submitButtonKey));
        // Drain the microtask queue so the awaited patch() resolves
        // before assertions.
        await tester.pump();
        await tester.pump();

        expect(notifier.patchCalls, hasLength(1));
        final ProfilePatch sent = notifier.patchCalls.single;
        expect(sent.githubUrl, equals(github));
        expect(sent.linkedinUrl, equals(linkedin));
        // The screen must not write to the goal field; the Set Goal
        // screen owns that step.
        expect(sent.goal, isNull);

        // toJson() shape mirrors the PATCH /profile/me request body so
        // the wire format is locked in.
        expect(
          sent.toJson(),
          equals(<String, dynamic>{
            'github_url': github,
            'linkedin_url': linkedin,
          }),
        );
      },
    );
  });
}
