/// Widget tests for [LoginScreen].
///
/// Verifies the screen's visual contract — gradient heading,
/// animated background, email field, neon CTA — and that the email
/// step transitions to the OTP step after a successful
/// `signInWithOtp` call. Supabase is replaced with a fake
/// [LoginAuthHandler] so the test does not stand up a real client.
///
/// `flutter_animate` schedules ongoing timers via `_AnimateState`
/// which the widget-tester's fake-async would otherwise flag at
/// teardown. We work around this by:
///   1. Wrapping the body in [tester.runAsync] so timers fire on
///      real time instead of fake time, and
///   2. Pumping a `SizedBox.shrink()` at the end of each test so
///      the animated background is disposed before the harness exits.
///
/// **Validates: Requirements 1.1, 10.4, 10.5**
library;

import 'package:devgrowth_ai/features/auth/presentation/login_screen.dart';
import 'package:devgrowth_ai/shared/widgets/animated_background.dart';
import 'package:devgrowth_ai/shared/widgets/gradient_text.dart';
import 'package:devgrowth_ai/shared/widgets/neon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLoginAuthHandler implements LoginAuthHandler {
  _FakeLoginAuthHandler();

  String? lastEmailForSend;
  String? lastEmailForVerify;
  String? lastTokenForVerify;
  int sendCalls = 0;
  int verifyCalls = 0;

  @override
  Future<void> sendOtp(String email) async {
    sendCalls += 1;
    lastEmailForSend = email;
  }

  @override
  Future<void> verifyOtp({required String email, required String token}) async {
    verifyCalls += 1;
    lastEmailForVerify = email;
    lastTokenForVerify = token;
  }
}

Widget _buildHarness(LoginAuthHandler handler) {
  return ProviderScope(
    child: MaterialApp(
      home: LoginScreen(authHandler: handler),
    ),
  );
}

/// Disposes the widget tree so `flutter_animate` timers stop and the
/// fake-async timer-pending invariant doesn't trip at teardown.
Future<void> _disposeHarness(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  group('LoginScreen', () {
    testWidgets(
      'renders the gradient heading, animated background, email field, and neon button',
      (WidgetTester tester) async {
        final _FakeLoginAuthHandler handler = _FakeLoginAuthHandler();

        await tester.runAsync(() async {
          await tester.pumpWidget(_buildHarness(handler));
          await tester.pump();

          // Animated background present on a top-level entry screen
          // (Requirement 10.5).
          expect(find.byType(AnimatedBackground), findsOneWidget);

          // Gradient heading (Requirement 10.4).
          expect(find.byType(GradientText), findsOneWidget);
          expect(find.text('DevGrowth AI'), findsOneWidget);

          // Email field is present and labeled.
          expect(find.byType(TextFormField), findsOneWidget);
          expect(find.text('Email'), findsOneWidget);

          // Primary CTA is a NeonButton (Requirement 10.3) that starts
          // on the "Send code" label (email-entry step).
          expect(find.byType(NeonButton), findsOneWidget);
          expect(find.text('Send code'), findsOneWidget);

          // No outbound calls until the user submits.
          expect(handler.sendCalls, 0);
        });

        await _disposeHarness(tester);
      },
    );

    testWidgets(
      'submits the email and advances to the OTP step',
      (WidgetTester tester) async {
        final _FakeLoginAuthHandler handler = _FakeLoginAuthHandler();

        await tester.runAsync(() async {
          await tester.pumpWidget(_buildHarness(handler));
          await tester.pump();

          await tester.enterText(
            find.byType(TextFormField).first,
            'dev@example.com',
          );

          await tester.tap(find.byType(NeonButton));
          // Run microtasks for the awaited sendOtp future.
          await tester.pump();
          await tester.pump();

          // The fake handler saw exactly one call with the typed email.
          expect(handler.sendCalls, 1);
          expect(handler.lastEmailForSend, 'dev@example.com');

          // The CTA flips to the OTP-step label.
          expect(find.text('Verify code'), findsOneWidget);
          expect(find.text('One-time code'), findsOneWidget);
        });

        await _disposeHarness(tester);
      },
    );

    testWidgets(
      'rejects an obviously invalid email without calling Supabase',
      (WidgetTester tester) async {
        final _FakeLoginAuthHandler handler = _FakeLoginAuthHandler();

        await tester.runAsync(() async {
          await tester.pumpWidget(_buildHarness(handler));
          await tester.pump();

          await tester.enterText(
            find.byType(TextFormField).first,
            'not-an-email',
          );

          await tester.tap(find.byType(NeonButton));
          await tester.pump();

          expect(handler.sendCalls, 0);
          expect(find.text('Enter a valid email address'), findsOneWidget);
        });

        await _disposeHarness(tester);
      },
    );
  });
}
