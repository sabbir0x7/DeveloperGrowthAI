/// Dio HTTP client with the Supabase JWT interceptor.
///
/// Owns the single configured [Dio] instance used by every feature
/// repository to talk to the FastAPI backend. The interceptor keeps two
/// invariants from `design.md` true on the wire:
///
///   * **Property 1 — Bearer JWT on every authenticated client request.**
///     Every outbound request whose path is not `/api/v1/auth/verify-token`
///     carries `Authorization: Bearer <accessToken>` matching the current
///     Supabase session, when one exists.
///
///   * **Property 25 — 401 responses clear session and route to `/login`.**
///     A 401 triggers exactly one refresh attempt; if that fails (or the
///     retried request fails again with 401), the local Supabase session
///     is cleared and the router is asked to navigate to `/login` via the
///     [OnUnauthorized] callback.
///
/// Wiring of the [OnUnauthorized] callback is deferred to the router task
/// (8.1). Until then the default no-op is used so unit tests and early
/// scaffolding do not crash on 401.
///
/// The interceptor talks to Supabase only through a small
/// [DioSessionController] seam so that the JWT-attach and 401-handler
/// behaviours can be unit-tested without booting Supabase. Production
/// callers continue to use [buildDio] with no extra arguments.
library;

import 'package:dio/dio.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'supabase_client.dart';

/// Path of the only backend endpoint that must NOT carry a Bearer token.
///
/// `verify-token` itself receives the JWT in its request body / Supabase
/// session and is exempt from the interceptor's auth header.
const String _kAuthExemptPath = '/api/v1/auth/verify-token';

/// Marker key on `RequestOptions.extra` used to ensure the 401-refresh
/// retry only fires once per original request.
const String _kRetriedExtraKey = '__retried__';

/// Callback invoked by the interceptor after it has cleared the local
/// Supabase session because a 401 could not be recovered with a refresh.
///
/// The router (task 8.1) wires this to push `/login`. Until then the
/// caller may pass `null`, in which case the callback is treated as a
/// no-op.
typedef OnUnauthorized = void Function();

/// Minimal seam over the Supabase auth client used by [buildDio].
///
/// Exposing only the three operations the interceptor needs keeps the
/// production code free of `Supabase.instance` lookups and lets tests
/// drive the 401 handler with a `mocktail` mock.
abstract class DioSessionController {
  /// Current access token, or `null` if the user is signed out.
  String? get accessToken;

  /// Attempts to refresh the session.
  ///
  /// Returns the new access token on success, or `null` (or throws) if
  /// the refresh failed and the caller should treat the original 401 as
  /// unrecoverable.
  Future<String?> refresh();

  /// Clears the local session, mirroring `auth.signOut()` semantics.
  Future<void> signOut();
}

/// Default [DioSessionController] backed by `Supabase.instance.client.auth`.
class _SupabaseDioSessionController implements DioSessionController {
  const _SupabaseDioSessionController();

  @override
  String? get accessToken => supabase.auth.currentSession?.accessToken;

  @override
  Future<String?> refresh() async {
    final AuthResponse response = await supabase.auth.refreshSession();
    return response.session?.accessToken;
  }

  @override
  Future<void> signOut() => supabase.auth.signOut();
}

/// Returns `true` when [path] is exempt from the JWT interceptor and must
/// be sent without an `Authorization` header.
///
/// The interceptor delegates to this helper so the exemption rule lives in
/// one place and is easy to extend if more public endpoints are added.
/// Both bare paths (`/api/v1/auth/verify-token`) and absolute URLs ending
/// in the exempt path are recognized.
bool isAuthExempt(String path) {
  if (path == _kAuthExemptPath) {
    return true;
  }
  return path.endsWith(_kAuthExemptPath);
}

/// Attaches the Supabase access token as a Bearer header on [options].
///
/// This is the pure helper the interceptor's `onRequest` callback
/// delegates to. Exposed as a top-level function so the JWT-attachment
/// invariant (Property 1, Requirement 1.3 / 9.5) can be exercised
/// directly by `frontend/test/property/dio_jwt_attach_test.dart`
/// without booting Supabase, Dio, or the network stack.
///
/// Behavior:
///   * If [accessToken] is `null` (no Supabase session), no header is
///     written. Any pre-existing `Authorization` header is left
///     untouched — the absence of a session means we should not be
///     overwriting whatever the caller set, and the interceptor never
///     sets one in this case anyway.
///   * If the resolved request path is auth-exempt (per
///     [isAuthExempt]), no header is written. Pre-existing headers are
///     again left untouched.
///   * Otherwise the header is set/overwritten to
///     `'Bearer <accessToken>'`. A stale Authorization value from a
///     previous session is replaced with the current token.
void attachJwtHeader(RequestOptions options, String? accessToken) {
  if (accessToken == null) {
    return;
  }
  if (isAuthExempt(options.path)) {
    return;
  }
  options.headers['Authorization'] = 'Bearer $accessToken';
}

/// Builds the configured [Dio] instance for talking to the backend.
///
/// The returned client:
///   * Uses [kApiBaseUrl] as its base URL.
///   * Has a 10-second connect timeout and a 30-second receive timeout.
///   * Sends JSON by default (`Content-Type: application/json`).
///   * Attaches the current Supabase access token as a Bearer header on
///     every request except the auth-exempt paths recognized by
///     [isAuthExempt].
///   * On a 401 response, attempts a single `refresh()` call on the
///     [DioSessionController] and retries the original request once. If
///     either step fails, it signs the user out locally and invokes
///     [onUnauthorized].
///
/// [onUnauthorized] defaults to a no-op so this builder is safe to call
/// before the router exists. [sessionController] defaults to a
/// Supabase-backed implementation; tests can pass a mock to drive the
/// interceptor without booting Supabase.
Dio buildDio({
  OnUnauthorized? onUnauthorized,
  DioSessionController? sessionController,
}) {
  final DioSessionController controller =
      sessionController ?? const _SupabaseDioSessionController();

  final Dio dio = Dio(
    BaseOptions(
      baseUrl: kApiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
    ),
  );

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
        attachJwtHeader(options, controller.accessToken);
        handler.next(options);
      },
      onError: (DioException err, ErrorInterceptorHandler handler) async {
        final RequestOptions options = err.requestOptions;
        final bool isUnauthorized = err.response?.statusCode == 401;
        final bool alreadyRetried = options.extra[_kRetriedExtraKey] == true;

        if (!isUnauthorized || alreadyRetried) {
          handler.next(err);
          return;
        }

        String? newToken;
        try {
          newToken = await controller.refresh();
        } catch (_) {
          newToken = null;
        }

        if (newToken == null) {
          await _handleUnrecoverable401(controller, onUnauthorized);
          handler.next(err);
          return;
        }

        options.extra[_kRetriedExtraKey] = true;
        options.headers['Authorization'] = 'Bearer $newToken';

        try {
          final Response<dynamic> response = await dio.fetch<dynamic>(options);
          handler.resolve(response);
        } catch (_) {
          await _handleUnrecoverable401(controller, onUnauthorized);
          handler.next(err);
        }
      },
    ),
  );

  return dio;
}

/// Best-effort cleanup after a 401 that could not be recovered.
///
/// Signs the user out via [controller] (swallowing any failure so the
/// callback still fires) and then invokes [onUnauthorized] so the router
/// can navigate to `/login`.
Future<void> _handleUnrecoverable401(
  DioSessionController controller,
  OnUnauthorized? onUnauthorized,
) async {
  try {
    await controller.signOut();
  } catch (_) {
    // Sign-out failures are non-fatal: the session is already invalid on
    // the server, and we still want to drop the user back to /login.
  }
  onUnauthorized?.call();
}
