/// Application-wide configuration constants.
///
/// Values are read from compile-time `--dart-define` arguments via
/// [String.fromEnvironment]. Each constant exposes a sensible localhost
/// default so the app can boot in a fresh dev environment without flags.
///
/// Example:
/// ```sh
/// flutter run \
///   --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///   --dart-define=SUPABASE_ANON_KEY=eyJhbGciOi... \
///   --dart-define=API_BASE_URL=http://127.0.0.1:8000
/// ```
library;

/// Supabase project URL.
///
/// Defaults to a local Supabase emulator/dev instance.
const String kSupabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'http://127.0.0.1:54321',
);

/// Supabase anonymous (publishable) key.
///
/// Defaults to an empty string so misconfiguration surfaces immediately
/// during `Supabase.initialize` rather than silently using a stale value.
const String kSupabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: '',
);

/// Base URL of the FastAPI backend.
///
/// Defaults to the local uvicorn dev server.
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);
