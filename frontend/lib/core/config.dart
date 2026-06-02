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
/// Defaults to the production Supabase project.
const String kSupabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://najksralfmbsmsjdcstl.supabase.co',
);

/// Supabase anonymous (publishable) key.
const String kSupabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5hamtzcmFsZm1ic21zamRjc3RsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk2OTU2MDksImV4cCI6MjA5NTI3MTYwOX0.t7EMNL7XbCLy_Xe3M0YSD5Eh0RaWV10R1XB6dEMKMG8',
);

/// Base URL of the FastAPI backend.
///
/// Defaults to the local uvicorn dev server for local testing.
/// For production APK use: https://developergrowthai.onrender.com
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);
