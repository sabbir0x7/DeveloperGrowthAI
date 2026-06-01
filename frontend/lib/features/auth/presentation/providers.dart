/// Riverpod providers for the auth feature.
///
/// Exposes [authProvider], a `StreamProvider<Session?>` that wraps
/// `Supabase.instance.client.auth.onAuthStateChange` and emits the
/// current [Session] (or `null` on sign-out) per design.md:
///
/// > `authProvider`  `StreamProvider<Session?>`  Wraps Supabase auth
/// > state changes.
///
/// The Route_Guard in `core/router.dart` uses this provider's value to
/// decide whether to redirect to `/login` (Property 24, Requirement 9.3),
/// and the dashboard / settings drawer use it to drive logout
/// (Requirement 1.6).
///
/// **Validates: Requirements 9.2, 9.3, 1.6**
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_client.dart';

/// Streams the current Supabase [Session] (or `null` on sign-out).
///
/// Implementation notes:
///   * Seeded with `supabase.auth.currentSession` so the very first
///     read after Supabase has restored a persisted session does not
///     fall through to `AsyncLoading` and incorrectly redirect to
///     `/login`.
///   * Maps each [AuthState] event to its `session` field so consumers
///     do not need to know about the [AuthChangeEvent] taxonomy.
final StreamProvider<Session?> authProvider = StreamProvider<Session?>(
  (Ref ref) async* {
    // Emit the current value immediately so consumers see the restored
    // session on the first frame instead of an AsyncLoading state.
    yield supabase.auth.currentSession;

    await for (final AuthState event in supabase.auth.onAuthStateChange) {
      yield event.session;
    }
  },
);

/// Convenience derived provider: `true` when a session currently exists.
///
/// The router's `redirect` callback reads this synchronously via
/// `ref.read`, so we expose it as a plain `Provider<bool>` derived from
/// [authProvider] rather than forcing every caller to deal with the
/// `AsyncValue<Session?>` shape.
final Provider<bool> hasSessionProvider = Provider<bool>((Ref ref) {
  final AsyncValue<Session?> auth = ref.watch(authProvider);
  return auth.maybeWhen<bool>(
    data: (Session? session) => session != null,
    orElse: () => supabase.auth.currentSession != null,
  );
});
