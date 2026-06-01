/// Cross-cutting Riverpod providers for the `core` layer.
///
/// Currently exposes a single shared [dioProvider] so every feature
/// repository talks to the backend through the same configured Dio
/// instance and JWT interceptor (see `core/dio_client.dart`).
///
/// The interceptor's 401 handler needs an `onUnauthorized` callback
/// that pushes `/login`. The router task (8.1) does not yet expose
/// that hook from a provider, so for now [dioProvider] passes `null`
/// and the interceptor falls back to its no-op default. A later task
/// can override [dioProvider] in `main.dart`'s `ProviderScope` with a
/// version that wires the router callback in.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dio_client.dart';

/// Shared [Dio] instance used by every feature repository.
///
/// Built via [buildDio] so it carries the Supabase JWT interceptor and
/// the 401 refresh-then-logout handler. The provider is `final` and
/// non-auto-dispose: a single Dio lives for the lifetime of the app.
final Provider<Dio> dioProvider = Provider<Dio>((Ref ref) {
  return buildDio();
});
