/// Supabase client bootstrap and session-stream accessors.
///
/// This module owns the single global Supabase instance for the app. It is
/// intentionally a thin wrapper over `supabase_flutter` so feature code can
/// depend on small, well-named helpers instead of `Supabase.instance.client`
/// directly.
///
/// Wiring into `main.dart` is deferred until the router and providers come
/// online in later tasks (see tasks 8.1 and 8.3).
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

/// Initializes the Supabase SDK using the compile-time configuration
/// constants from [config.dart].
///
/// Call this exactly once at app startup before any code touches
/// [supabase].
Future<void> initSupabase() async {
  await Supabase.initialize(
    url: kSupabaseUrl,
    anonKey: kSupabaseAnonKey,
  );
}

/// The shared Supabase client. Safe to read after [initSupabase] completes.
SupabaseClient get supabase => Supabase.instance.client;

/// Stream of authentication state changes (sign-in, sign-out, token
/// refresh, etc.). Backed by Supabase's `onAuthStateChange` broadcast
/// stream.
Stream<AuthState> authStateChanges() => supabase.auth.onAuthStateChange;

/// The currently authenticated session, or `null` if the user is signed
/// out or has not yet been restored from local storage.
Session? currentSession() => supabase.auth.currentSession;
