/// Property test for the Dio 401 handler.
///
/// **Property 25 — 401 responses clear session and route to /login.**
///
/// For any HTTP response with status 401 received by the Dio
/// interceptor (after a single refresh attempt has also failed), the
/// local Supabase session is cleared and the router's current location
/// becomes `/login`.
///
/// The interceptor in `buildDio()` talks to Supabase only through the
/// abstract [DioSessionController] seam and to the router only through
/// the [OnUnauthorized] callback, so this test drives both with
/// `mocktail` / lambdas instead of booting the SDKs. A custom
/// [HttpClientAdapter] stub returns canned responses without any real
/// HTTP calls.
///
/// Three cases are exercised across many randomized trials so the
/// property holds for any combination of initial path, status code,
/// and refresh outcome:
///
///   * **Unrecoverable 401** — the initial 401 cannot be recovered.
///     This is exercised in three sub-variants:
///       0. `refresh()` returns `null`.
///       1. `refresh()` throws.
///       2. `refresh()` returns a new token but the retried request
///          also returns 401.
///     In every case `signOut()` MUST be called exactly once and the
///     `onUnauthorized` callback MUST fire exactly once.
///
///   * **Recoverable 401** — `refresh()` returns a new access token
///     and the retried request succeeds. `signOut()` MUST NOT be
///     called and `onUnauthorized` MUST NOT fire. The retry MUST
///     carry the new token in its `Authorization` header.
///
///   * **Non-401 responses** — for any random non-401 status code
///     (2xx, 4xx ≠ 401, 5xx) the interceptor MUST NOT touch the
///     session: no `signOut()`, no `refresh()`, no `onUnauthorized`.
///
/// **Validates: Requirement 9.6**
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:devgrowth_ai/core/dio_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Number of random iterations per property. The design doc requires
/// each property test to run at least 100 iterations.
const int _iterations = 100;

/// `mocktail` mock of the [DioSessionController] seam.
class _MockSessionController extends Mock implements DioSessionController {}

/// Programmable [HttpClientAdapter] stub.
///
/// Each call invokes [_responder] with the request options and the
/// zero-based call index. The adapter records every request it served
/// so tests can assert on retry behaviour and per-request headers.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._responder);

  final ResponseBody Function(RequestOptions options, int callIndex)
      _responder;

  /// All requests this adapter served, in arrival order.
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final int idx = requests.length;
    requests.add(options);
    return _responder(options, idx);
  }

  @override
  void close({bool force = false}) {}
}

/// Builds a JSON [ResponseBody] with the given [status] and [body].
ResponseBody _jsonResponse(int status, Map<String, dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    },
  );
}

/// Pool of realistic backend paths the Dio client might be asked to
/// hit. Property iterations pick a random entry from this list to
/// confirm the 401 handler's behaviour does not depend on the path.
const List<String> _samplePaths = <String>[
  '/api/v1/profile/me',
  '/api/v1/profile/settings',
  '/api/v1/analysis/run',
  '/api/v1/analysis/latest',
  '/api/v1/auth/whoami',
  '/health',
  '/',
];

String _randomPath(Random rng) =>
    _samplePaths[rng.nextInt(_samplePaths.length)];

/// Generates a random JWT-shaped token string with the given [prefix]
/// so failing assertions clearly distinguish the "old" token from the
/// "new" one.
String _randomToken(Random rng, String prefix) {
  const String alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.';
  final int length = 16 + rng.nextInt(48);
  final StringBuffer buf = StringBuffer(prefix);
  for (int i = 0; i < length; i++) {
    buf.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}

void main() {
  group('Property 25: 401 responses clear session and route to /login', () {
    test(
      'unrecoverable 401 calls signOut() exactly once and fires '
      'onUnauthorized exactly once',
      () async {
        final Random rng = Random(0xA11CEBEEF);

        for (int i = 0; i < _iterations; i++) {
          final _MockSessionController mock = _MockSessionController();
          final String initialToken = _randomToken(rng, 'init-');
          final String newToken = _randomToken(rng, 'new-');
          String? current = initialToken;

          // Three unrecoverable variants exercised uniformly at random.
          //   0: refresh() returns null
          //   1: refresh() throws
          //   2: refresh() returns a token but the retried request 401s
          final int variant = rng.nextInt(3);

          when(() => mock.accessToken).thenAnswer((_) => current);
          when(() => mock.refresh()).thenAnswer((_) async {
            switch (variant) {
              case 0:
                return null;
              case 1:
                throw Exception('refresh blew up');
              default:
                current = newToken;
                return newToken;
            }
          });
          when(() => mock.signOut()).thenAnswer((_) async {});

          int callbackCount = 0;
          final Dio dio = buildDio(
            sessionController: mock,
            onUnauthorized: () => callbackCount++,
          );

          // Both responses are 401 — covers the "first 401 cannot be
          // refreshed" variants (0/1, where there is no retry) and the
          // "refreshed retry also 401s" variant (2) with a single
          // adapter rule.
          final _StubAdapter adapter = _StubAdapter(
            (RequestOptions options, int idx) =>
                _jsonResponse(401, <String, dynamic>{'detail': 'unauth'}),
          );
          dio.httpClientAdapter = adapter;

          final String path = _randomPath(rng);
          DioException? caught;
          try {
            await dio.get<dynamic>(path);
          } on DioException catch (e) {
            caught = e;
          }

          expect(
            caught,
            isNotNull,
            reason: 'iteration $i variant $variant: an unrecoverable '
                '401 must propagate as a DioException to the caller',
          );
          verify(() => mock.signOut()).called(1);
          expect(
            callbackCount,
            equals(1),
            reason: 'iteration $i variant $variant path="$path": '
                'onUnauthorized should fire exactly once for an '
                'unrecoverable 401',
          );

          // Variant 2 must have produced a retry; variants 0/1 must not
          // have. This guards against a regression in the retry gate.
          if (variant == 2) {
            expect(
              adapter.requests.length,
              equals(2),
              reason: 'iteration $i: variant 2 must retry exactly once',
            );
          } else {
            expect(
              adapter.requests.length,
              equals(1),
              reason: 'iteration $i variant $variant: '
                  'no retry should fire when refresh fails',
            );
          }
        }
      },
    );

    test(
      'recoverable 401 does not sign out, does not fire onUnauthorized, '
      'and the retry carries the new token',
      () async {
        final Random rng = Random(0xB0BCAFE);

        for (int i = 0; i < _iterations; i++) {
          final _MockSessionController mock = _MockSessionController();
          final String initialToken = _randomToken(rng, 'init-');
          final String newToken = _randomToken(rng, 'new-');
          String? current = initialToken;

          when(() => mock.accessToken).thenAnswer((_) => current);
          when(() => mock.refresh()).thenAnswer((_) async {
            current = newToken;
            return newToken;
          });
          when(() => mock.signOut()).thenAnswer((_) async {});

          int callbackCount = 0;
          final Dio dio = buildDio(
            sessionController: mock,
            onUnauthorized: () => callbackCount++,
          );

          final _StubAdapter adapter = _StubAdapter(
            (RequestOptions options, int idx) {
              if (idx == 0) {
                return _jsonResponse(
                  401,
                  <String, dynamic>{'detail': 'unauth'},
                );
              }
              return _jsonResponse(200, <String, dynamic>{'ok': true});
            },
          );
          dio.httpClientAdapter = adapter;

          final String path = _randomPath(rng);
          final Response<dynamic> response = await dio.get<dynamic>(path);

          expect(
            response.statusCode,
            equals(200),
            reason: 'iteration $i path="$path": recoverable 401 should '
                'resolve to the retried 200 response',
          );
          verifyNever(() => mock.signOut());
          expect(
            callbackCount,
            equals(0),
            reason: 'iteration $i path="$path": onUnauthorized must '
                'NOT fire when the 401 is recovered',
          );
          expect(
            adapter.requests.length,
            equals(2),
            reason: 'iteration $i path="$path": exactly one retry '
                'must follow the original request',
          );
          expect(
            adapter.requests[1].headers['Authorization'],
            equals('Bearer $newToken'),
            reason: 'iteration $i path="$path": the retry must carry '
                'the new token in its Authorization header',
          );
        }
      },
    );

    test(
      'non-401 responses never trigger signOut(), refresh(), or '
      'onUnauthorized',
      () async {
        final Random rng = Random(0xCAFEF00D);
        // A representative spread of 2xx, 4xx (other than 401), and
        // 5xx codes. None of these should touch the session.
        const List<int> nonUnauthorizedCodes = <int>[
          200,
          201,
          204,
          400,
          403,
          404,
          412,
          422,
          429,
          500,
          502,
          503,
        ];

        for (int i = 0; i < _iterations; i++) {
          final _MockSessionController mock = _MockSessionController();
          final String initialToken = _randomToken(rng, 'init-');
          when(() => mock.accessToken).thenAnswer((_) => initialToken);
          // Even if refresh were called, return null so we'd notice it
          // — but we expect verifyNever() below.
          when(() => mock.refresh()).thenAnswer((_) async => null);
          when(() => mock.signOut()).thenAnswer((_) async {});

          int callbackCount = 0;
          final Dio dio = buildDio(
            sessionController: mock,
            onUnauthorized: () => callbackCount++,
          );

          final int code =
              nonUnauthorizedCodes[rng.nextInt(nonUnauthorizedCodes.length)];
          final _StubAdapter adapter = _StubAdapter(
            (RequestOptions options, int idx) =>
                _jsonResponse(code, <String, dynamic>{'status': code}),
          );
          dio.httpClientAdapter = adapter;

          final String path = _randomPath(rng);
          try {
            await dio.get<dynamic>(path);
          } on DioException catch (_) {
            // Non-2xx responses surface as DioException by default.
            // We only care about session-related side effects here.
          }

          verifyNever(() => mock.signOut());
          verifyNever(() => mock.refresh());
          expect(
            callbackCount,
            equals(0),
            reason: 'iteration $i status=$code path="$path": '
                'onUnauthorized must not fire for non-401 responses',
          );
          expect(
            adapter.requests.length,
            equals(1),
            reason: 'iteration $i status=$code path="$path": '
                'no retry should fire for a non-401 response',
          );
        }
      },
    );
  });
}
