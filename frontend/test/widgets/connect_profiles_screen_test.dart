/// Widget tests for [ConnectProfilesScreen].
///
/// Pumps the screen under a [ProviderScope] with [profileProvider]
/// overridden to a fake notifier that records every `patch()` call so
/// assertions can verify that submit calls `PATCH /profile/me`.
library;

import 'package:devgrowth_ai/core/providers.dart';
import 'package:devgrowth_ai/features/onboarding/domain/profile.dart';
import 'package:devgrowth_ai/features/onboarding/presentation/connect_profiles_screen.dart';
import 'package:devgrowth_ai/features/onboarding/presentation/providers.dart';
import 'package:devgrowth_ai/shared/widgets/animated_background.dart';
import 'package:devgrowth_ai/shared/widgets/gradient_text.dart';
import 'package:devgrowth_ai/shared/widgets/neon_button.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _FakeProfileNotifier extends ProfileNotifier {
  _FakeProfileNotifier();

  final List<ProfilePatch> patchCalls = <ProfilePatch>[];

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

class _MockDio extends Mock implements Dio {}
class _MockResponse extends Mock implements Response<dynamic> {}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _FakeProfileNotifier notifier,
  required Dio dio,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileProvider.overrideWith(() => notifier),
        dioProvider.overrideWithValue(dio),
      ],
      child: const MaterialApp(
        home: ConnectProfilesScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  late _MockDio mockDio;

  setUpAll(() {
    registerFallbackValue(RequestOptions(path: ''));
  });

  setUp(() {
    mockDio = _MockDio();

    // Mock MethodChannel for url_launcher
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'canLaunch') {
        return true;
      }
      if (methodCall.method == 'launch') {
        return true;
      }
      return null;
    });
  });

  group('ConnectProfilesScreen', () {
    testWidgets(
      'renders heading, animated background, buttons, and continue button',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();

        await _pumpScreen(tester, notifier: notifier, dio: mockDio);

        expect(find.byType(AnimatedBackground), findsOneWidget);
        expect(find.byKey(ConnectProfilesScreen.headingKey), findsOneWidget);
        expect(find.byType(GradientText), findsAtLeastNWidgets(1));

        // GitHub connect button
        expect(
          find.byKey(ConnectProfilesScreen.connectGithubButtonKey),
          findsOneWidget,
        );
        // LinkedIn connect button
        expect(
          find.byKey(ConnectProfilesScreen.uploadLinkedinButtonKey),
          findsOneWidget,
        );

        // Continue button (disabled by default since GitHub is not connected)
        expect(
          find.byKey(ConnectProfilesScreen.continueButtonKey),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Continue button triggers notifier patch when GitHub is connected',
      (WidgetTester tester) async {
        final _FakeProfileNotifier notifier = _FakeProfileNotifier();

        // Stub Dio connection endpoint for GitHub
        final _MockResponse response = _MockResponse();
        when(() => response.data).thenReturn(<String, dynamic>{
          'authorize_url': 'https://github.com/login/oauth/authorize?client_id=123&state=abc',
        });
        when(() => mockDio.get<dynamic>('/api/v1/auth/github/connect'))
            .thenAnswer((_) async => response);

        await _pumpScreen(tester, notifier: notifier, dio: mockDio);

        // Tap connect GitHub. This triggers HTTP call and shows dialog.
        await tester.tap(find.byKey(ConnectProfilesScreen.connectGithubButtonKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        // The dialog pops up asking the user to complete GitHub connection.
        // Click "Done" to simulate success.
        expect(find.text('GitHub Connection'), findsOneWidget);
        await tester.tap(find.text('Done'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        // Now GitHub should be connected and the Continue button should be enabled.
        final Finder continueBtnFinder = find.byKey(ConnectProfilesScreen.continueButtonKey);
        expect(tester.widget<NeonButton>(continueBtnFinder).onPressed, isNotNull);

        await tester.tap(continueBtnFinder);
        await tester.pump();

        expect(notifier.patchCalls, hasLength(1));
        final ProfilePatch sent = notifier.patchCalls.single;
        expect(sent.githubUrl, equals('https://github.com/connected'));
        expect(sent.linkedinUrl, equals('https://linkedin.com/in/connected'));
      },
    );
  });
}
