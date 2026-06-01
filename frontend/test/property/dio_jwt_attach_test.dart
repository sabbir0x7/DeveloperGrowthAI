/// Property test for the Dio JWT-attachment interceptor.
///
/// **Property 1 — Bearer JWT on every authenticated client request.**
///
/// For any random access-token string `t` and any backend path `p`:
///   * If `p` is exempt (matches `/api/v1/auth/verify-token`), the
///     `Authorization` header MUST NOT be set by [attachJwtHeader].
///   * Otherwise, when a Supabase session exists (modelled here as a
///     non-null token), the `Authorization` header MUST equal
///     `'Bearer $t'`.
///
/// The interceptor in `buildDio()` delegates to [attachJwtHeader] with
/// `Supabase.instance.client.auth.currentSession?.accessToken`, so
/// validating the helper across many random inputs validates the
/// interceptor's contract without bootstrapping the Supabase SDK in a
/// unit test.
///
/// **Validates: Requirements 1.3, 9.5**
library;

import 'dart:math';

import 'package:dio/dio.dart';
import 'package:devgrowth_ai/core/dio_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exempt path the interceptor must NOT carry an Authorization
/// header on. Kept in sync with the constant in `dio_client.dart`.
const String _exemptPath = '/api/v1/auth/verify-token';

/// Number of random iterations per property. The design doc requires
/// each property test to run at least 100 iterations.
const int _iterations = 100;

/// Builds a [RequestOptions] with the given [path] and any pre-existing
/// headers a real Dio request might carry.
RequestOptions _options(String path) =>
    RequestOptions(path: path, headers: <String, dynamic>{
      'Content-Type': 'application/json',
    });

/// Generates a random non-exempt path. We pick from a pool of realistic
/// API paths plus completely random strings, then reject anything that
/// would be classified as exempt by [isAuthExempt].
String _randomNonExemptPath(Random rng) {
  const List<String> samplePaths = <String>[
    '/api/v1/profile/me',
    '/api/v1/profile/settings',
    '/api/v1/analysis/run',
    '/api/v1/analysis/latest',
    '/api/v1/auth/whoami',
    '/v2/analysis',
    '/health',
    '/',
    'analysis/run',
    'https://api.example.com/api/v1/profile/me',
  ];

  while (true) {
    final String candidate;
    if (rng.nextBool()) {
      candidate = samplePaths[rng.nextInt(samplePaths.length)];
    } else {
      candidate = _randomString(rng, minLen: 1, maxLen: 64);
    }
    if (!isAuthExempt(candidate)) {
      return candidate;
    }
  }
}

/// Generates a random exempt-by-suffix path. Always ends in the exempt
/// suffix so [isAuthExempt] returns `true`.
String _randomExemptPath(Random rng) {
  // 1-in-3: bare exempt path. Otherwise prefix with random junk so we
  // also cover absolute-URL forms like
  // `https://api.example.com/api/v1/auth/verify-token`.
  if (rng.nextInt(3) == 0) {
    return _exemptPath;
  }
  final String prefix = _randomString(rng, minLen: 0, maxLen: 32);
  return '$prefix$_exemptPath';
}

/// Generates a random non-empty token string. Tokens may contain any
/// printable ASCII to mimic the wide range of JWT-shaped strings the
/// Supabase SDK could hand the interceptor.
String _randomToken(Random rng) =>
    _randomString(rng, minLen: 1, maxLen: 256, alphabet: _tokenAlphabet);

String _randomString(
  Random rng, {
  required int minLen,
  required int maxLen,
  String alphabet = _pathAlphabet,
}) {
  final int length = minLen + rng.nextInt(maxLen - minLen + 1);
  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < length; i++) {
    buf.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}

// Path-shaped characters: letters, digits, slashes, dashes, dots.
const String _pathAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._';

// JWT-shaped characters: base64url alphabet plus the dot separators
// JWTs use, so we can also test plain random strings as tokens.
const String _tokenAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.';

void main() {
  group('Property 1: Bearer JWT on every authenticated client request', () {
    test(
        'attaches Authorization: Bearer <token> on every non-exempt path '
        'when a session exists', () {
      final Random rng = Random(0xDEADBEEF);

      for (int i = 0; i < _iterations; i++) {
        final String path = _randomNonExemptPath(rng);
        final String token = _randomToken(rng);
        final RequestOptions options = _options(path);

        attachJwtHeader(options, token);

        expect(
          options.headers['Authorization'],
          equals('Bearer $token'),
          reason: 'iteration $i: path="$path", token="$token" '
              'should have produced "Bearer $token"',
        );
        // Exempt paths should never reach this branch; double-check the
        // generator's invariant so a faulty generator does not silently
        // pass the property.
        expect(
          isAuthExempt(path),
          isFalse,
          reason: 'iteration $i: generator produced an exempt path "$path"',
        );
      }
    });

    test(
        'does NOT attach Authorization on /api/v1/auth/verify-token '
        '(or any path matching that suffix), even when a session exists',
        () {
      final Random rng = Random(0xC0FFEE);

      for (int i = 0; i < _iterations; i++) {
        final String path = _randomExemptPath(rng);
        final String token = _randomToken(rng);
        final RequestOptions options = _options(path);

        attachJwtHeader(options, token);

        expect(
          options.headers.containsKey('Authorization'),
          isFalse,
          reason: 'iteration $i: exempt path "$path" must not carry '
              'an Authorization header',
        );
        expect(
          isAuthExempt(path),
          isTrue,
          reason: 'iteration $i: generator produced a non-exempt path '
              '"$path" by mistake',
        );
      }
    });

    test(
        'does NOT attach Authorization when there is no session '
        '(token is null), regardless of path', () {
      final Random rng = Random(0x1234ABCD);

      for (int i = 0; i < _iterations; i++) {
        // Mix exempt and non-exempt paths so we cover both branches.
        final String path =
            rng.nextBool() ? _randomNonExemptPath(rng) : _randomExemptPath(rng);
        final RequestOptions options = _options(path);

        attachJwtHeader(options, null);

        expect(
          options.headers.containsKey('Authorization'),
          isFalse,
          reason:
              'iteration $i: no session should never produce an '
              'Authorization header (path="$path")',
        );
      }
    });

    test(
        'overwrites any pre-existing Authorization header with the '
        'session token on non-exempt paths', () {
      final Random rng = Random(0xBADC0DE);

      for (int i = 0; i < _iterations; i++) {
        final String path = _randomNonExemptPath(rng);
        final String token = _randomToken(rng);
        final RequestOptions options = _options(path)
          ..headers['Authorization'] = 'Bearer stale-${_randomToken(rng)}';

        attachJwtHeader(options, token);

        expect(
          options.headers['Authorization'],
          equals('Bearer $token'),
          reason: 'iteration $i: stale Authorization on "$path" should '
              'have been overwritten with the current session token',
        );
      }
    });
  });
}
