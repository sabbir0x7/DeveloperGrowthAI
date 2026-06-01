/// Property tests for the Settings drawer.
///
/// **Property 27 — AI key input is masked and never pre-filled.**
///
/// For any state of the [settingsProvider], the AI key [TextField] in
/// the [SettingsDrawer] always has `obscureText: true` and its
/// controller text is empty (the key is never pre-filled from the
/// server response). This ensures the raw AI key is never visible in
/// the UI, regardless of the settings state.
///
/// **Validates: Requirement 11.3**
///
/// **Property 28 — "Key configured" indicator tracks has_ai_key.**
///
/// For any [Settings] value where `hasAiKey` is `true`, the drawer
/// renders the text "AI key configured". For any [Settings] value
/// where `hasAiKey` is `false`, the drawer renders "No AI key
/// configured". The indicator always reflects the current boolean
/// state from the provider.
///
/// **Validates: Requirement 11.4**
library;

import 'dart:math';

import 'package:devgrowth_ai/features/dashboard/domain/analysis_models.dart';
import 'package:devgrowth_ai/features/dashboard/presentation/providers.dart';
import 'package:devgrowth_ai/features/dashboard/presentation/settings_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Number of random iterations per property.
const int _iterations = 100;

/// Characters used to build random base URL strings.
const String _urlAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-./';

/// Generates a random base URL string.
String _randomBaseUrl(Random rng) {
  final int length = 10 + rng.nextInt(40);
  final StringBuffer buf = StringBuffer('https://');
  for (int i = 0; i < length; i++) {
    buf.write(_urlAlphabet[rng.nextInt(_urlAlphabet.length)]);
  }
  return buf.toString();
}

/// Generates a random [Settings] instance with a random `hasAiKey`
/// boolean and a random base URL.
Settings _randomSettings(Random rng) {
  return Settings(
    hasAiKey: rng.nextBool(),
    aiProviderBaseUrl: _randomBaseUrl(rng),
  );
}

/// Generates a random [Settings] with a specific `hasAiKey` value.
Settings _settingsWithKey(Random rng, {required bool hasAiKey}) {
  return Settings(
    hasAiKey: hasAiKey,
    aiProviderBaseUrl: _randomBaseUrl(rng),
  );
}

/// Pumps the [SettingsDrawer] inside a [MaterialApp] with the
/// [settingsProvider] overridden to return the given [AsyncValue].
///
/// Renders the drawer directly in the body (not as an endDrawer) to
/// avoid drawer-open animation timing issues across iterations.
/// Uses a [UniqueKey] on the ProviderScope to force a full rebuild
/// on each iteration so the notifier state is fresh.
Future<void> _pumpDrawer(
  WidgetTester tester, {
  required AsyncValue<Settings> settingsValue,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        settingsProvider.overrideWith(() => _FakeSettingsNotifier(settingsValue)),
      ],
      child: MaterialApp(
        home: Material(
          child: SizedBox(
            width: 400,
            height: 1200,
            child: const SettingsDrawer(),
          ),
        ),
      ),
    ),
  );

  // Allow the async notifier to resolve and the widget tree to settle.
  await tester.pumpAndSettle();
}

/// A fake [SettingsNotifier] that returns a pre-set [AsyncValue].
class _FakeSettingsNotifier extends SettingsNotifier {
  _FakeSettingsNotifier(this._value);

  final AsyncValue<Settings> _value;

  @override
  Future<Settings> build() async {
    if (_value is AsyncData<Settings>) {
      return (_value as AsyncData<Settings>).value;
    }
    if (_value is AsyncError<Settings>) {
      // ignore: only_throw_errors
      throw (_value as AsyncError<Settings>).error;
    }
    // For loading state, return a future that never completes.
    return Future<Settings>.delayed(const Duration(days: 1));
  }
}

void main() {
  group('Property 27: AI key input is masked and never pre-filled', () {
    testWidgets(
      'AI key TextField always has obscureText=true and empty controller '
      'regardless of settings state',
      (WidgetTester tester) async {
        final Random rng = Random(0xE0A20001);

        for (int i = 0; i < _iterations; i++) {
          final Settings settings = _randomSettings(rng);
          final AsyncValue<Settings> value = AsyncData<Settings>(settings);

          await _pumpDrawer(tester, settingsValue: value);

          // Find the AI Key TextField by its label text.
          final Finder aiKeyField = find.widgetWithText(TextField, 'AI Key');
          expect(
            aiKeyField,
            findsOneWidget,
            reason: 'iteration $i: AI Key TextField must be present',
          );

          final TextField textField =
              tester.widget<TextField>(aiKeyField);

          // Property 27a: obscureText must always be true.
          expect(
            textField.obscureText,
            isTrue,
            reason: 'iteration $i: AI Key TextField must have '
                'obscureText=true (hasAiKey=${settings.hasAiKey})',
          );

          // Property 27b: controller text must always be empty
          // (key is never pre-filled).
          expect(
            textField.controller?.text ?? '',
            isEmpty,
            reason: 'iteration $i: AI Key TextField controller must be '
                'empty (hasAiKey=${settings.hasAiKey})',
          );
        }
      },
    );
  });

  group('Property 28: "Key configured" indicator tracks has_ai_key', () {
    testWidgets(
      'has_ai_key=true shows "AI key configured"; '
      'has_ai_key=false shows "No AI key configured"',
      (WidgetTester tester) async {
        final Random rng = Random(0xE0A20002);

        for (int i = 0; i < _iterations; i++) {
          final bool hasKey = rng.nextBool();
          final Settings settings =
              _settingsWithKey(rng, hasAiKey: hasKey);
          final AsyncValue<Settings> value = AsyncData<Settings>(settings);

          await _pumpDrawer(tester, settingsValue: value);

          if (hasKey) {
            expect(
              find.text('AI key configured'),
              findsOneWidget,
              reason: 'iteration $i: hasAiKey=true must show '
                  '"AI key configured"',
            );
            expect(
              find.text('No AI key configured'),
              findsNothing,
              reason: 'iteration $i: hasAiKey=true must NOT show '
                  '"No AI key configured"',
            );
          } else {
            expect(
              find.text('No AI key configured'),
              findsOneWidget,
              reason: 'iteration $i: hasAiKey=false must show '
                  '"No AI key configured"',
            );
            expect(
              find.text('AI key configured'),
              findsNothing,
              reason: 'iteration $i: hasAiKey=false must NOT show '
                  '"AI key configured"',
            );
          }
        }
      },
    );
  });
}
