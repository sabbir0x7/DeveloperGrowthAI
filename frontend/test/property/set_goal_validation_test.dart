/// Property test for goal input validation.
///
/// **Property 6 — Goal validation rejects empty and oversize input.**
///
/// The pure [validateGoal] function from
/// `lib/features/onboarding/presentation/set_goal_screen.dart` must:
///   * Reject empty strings (return a non-null error message).
///   * Reject whitespace-only strings (return a non-null error message).
///   * Reject strings longer than [kGoalMaxLength] (500) characters.
///   * Accept valid strings (1–500 chars with at least one non-whitespace
///     character) by returning `null`.
///
/// The test exercises the function across 100 random iterations per
/// sub-property, generating inputs from the full space of invalid and
/// valid strings so the contract holds for any input.
///
/// **Validates: Requirement 3.4**
library;

import 'dart:math';

import 'package:devgrowth_ai/features/onboarding/presentation/set_goal_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Number of random iterations per property.
const int _iterations = 100;

/// Characters used to build random valid goal strings.
const String _goalAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?-';

/// Generates a random whitespace-only string of length 1..maxLen.
String _randomWhitespace(Random rng, {int maxLen = 50}) {
  const List<String> whitespaceChars = <String>[' ', '\t', '\n', '\r'];
  final int length = 1 + rng.nextInt(maxLen);
  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < length; i++) {
    buf.write(whitespaceChars[rng.nextInt(whitespaceChars.length)]);
  }
  return buf.toString();
}

/// Generates a random string longer than [kGoalMaxLength].
String _randomOversizeString(Random rng) {
  final int length = kGoalMaxLength + 1 + rng.nextInt(500);
  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < length; i++) {
    buf.write(_goalAlphabet[rng.nextInt(_goalAlphabet.length)]);
  }
  return buf.toString();
}

/// Generates a random valid goal string (1–[kGoalMaxLength] chars,
/// containing at least one non-whitespace character).
String _randomValidGoal(Random rng) {
  final int length = 1 + rng.nextInt(kGoalMaxLength);
  final StringBuffer buf = StringBuffer();
  // Ensure at least one non-whitespace character at a random position.
  final int nonWsPos = rng.nextInt(length);
  for (int i = 0; i < length; i++) {
    if (i == nonWsPos) {
      // Pick a non-whitespace character.
      const String nonWs =
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?-';
      buf.write(nonWs[rng.nextInt(nonWs.length)]);
    } else {
      buf.write(_goalAlphabet[rng.nextInt(_goalAlphabet.length)]);
    }
  }
  return buf.toString();
}

void main() {
  group('Property 6: Goal validation rejects empty and oversize input', () {
    test('empty string is always rejected', () {
      // Empty string is deterministic — one case, but we still loop
      // to match the iteration pattern and confirm stability.
      for (int i = 0; i < _iterations; i++) {
        final String? result = validateGoal('');
        expect(
          result,
          isNotNull,
          reason: 'iteration $i: empty string must be rejected',
        );
      }
    });

    test('whitespace-only strings are always rejected', () {
      final Random rng = Random(0xD0A10001);

      for (int i = 0; i < _iterations; i++) {
        final String input = _randomWhitespace(rng);
        final String? result = validateGoal(input);

        expect(
          result,
          isNotNull,
          reason: 'iteration $i: whitespace-only string '
              '(length=${input.length}) must be rejected '
              '(got null = accepted)',
        );
      }
    });

    test('strings longer than kGoalMaxLength are always rejected', () {
      final Random rng = Random(0xD0A10002);

      for (int i = 0; i < _iterations; i++) {
        final String input = _randomOversizeString(rng);
        final String? result = validateGoal(input);

        expect(
          result,
          isNotNull,
          reason: 'iteration $i: oversize string (length=${input.length}, '
              'max=$kGoalMaxLength) must be rejected (got null = accepted)',
        );
      }
    });

    test('valid strings (1–$kGoalMaxLength chars, non-whitespace) are accepted',
        () {
      final Random rng = Random(0xD0A10003);

      for (int i = 0; i < _iterations; i++) {
        final String input = _randomValidGoal(rng);
        final String? result = validateGoal(input);

        expect(
          result,
          isNull,
          reason: 'iteration $i: valid goal (length=${input.length}) '
              'must be accepted (got error: "$result")',
        );
      }
    });

    test('boundary: exactly kGoalMaxLength chars is accepted', () {
      final Random rng = Random(0xD0A10004);

      for (int i = 0; i < _iterations; i++) {
        final StringBuffer buf = StringBuffer();
        for (int j = 0; j < kGoalMaxLength; j++) {
          buf.write(_goalAlphabet[rng.nextInt(_goalAlphabet.length)]);
        }
        // Ensure at least one non-whitespace char.
        final String raw = buf.toString();
        final String input = raw.trim().isEmpty
            ? 'a${raw.substring(1)}'
            : raw;

        expect(
          input.length,
          equals(kGoalMaxLength),
          reason: 'iteration $i: generated string must be exactly '
              '$kGoalMaxLength chars',
        );

        final String? result = validateGoal(input);
        expect(
          result,
          isNull,
          reason: 'iteration $i: exactly $kGoalMaxLength chars must be '
              'accepted (got error: "$result")',
        );
      }
    });

    test('boundary: kGoalMaxLength + 1 chars is rejected', () {
      final Random rng = Random(0xD0A10005);

      for (int i = 0; i < _iterations; i++) {
        final StringBuffer buf = StringBuffer();
        for (int j = 0; j < kGoalMaxLength + 1; j++) {
          buf.write(_goalAlphabet[rng.nextInt(_goalAlphabet.length)]);
        }
        final String input = buf.toString();

        expect(
          input.length,
          equals(kGoalMaxLength + 1),
          reason: 'iteration $i: generated string must be exactly '
              '${kGoalMaxLength + 1} chars',
        );

        final String? result = validateGoal(input);
        expect(
          result,
          isNotNull,
          reason: 'iteration $i: ${kGoalMaxLength + 1} chars must be '
              'rejected (got null = accepted)',
        );
      }
    });
  });
}
