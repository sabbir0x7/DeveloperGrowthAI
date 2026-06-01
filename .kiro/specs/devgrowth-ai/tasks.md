# Implementation Plan: DevGrowth AI

## Overview

This plan converts the design into incremental coding tasks following a strict bottom-up execution order:

1. **Supabase**: tables, RLS, and the `handle_new_user` trigger.
2. **FastAPI scaffolding**: project layout, env config, JWT verification, Fernet encryption.
3. **Backend services and endpoints**: schemas, middleware, settings/AI/profile/analysis services, then HTTP routes and app wiring.
4. **Flutter app**: GoRouter and Route_Guard, Riverpod providers, glassmorphism shared widgets, then the four feature screens (Login, Connect Profiles, Set Goal, Dashboard) plus the Settings drawer.

Property tests are placed next to the code they validate so failures surface as early as possible. Each property test sub-task names the property number from `design.md` and the requirement clauses it validates.

## Tasks

- [x] 1. Supabase database schema and Row-Level Security
  - [x] 1.1 Create the SQL migration that defines `users`, `user_settings`, `analyses`, `skills`, and `roadmaps` tables
    - File: `supabase/migrations/0001_init_schema.sql`
    - Match column names and types from the ER diagram in design.md (e.g. `users.id` = `auth.uid()`, `user_settings.encrypted_ai_key bytea`, `analyses.result_json jsonb`, etc.)
    - Add foreign keys from each owned table to `users(id)` with `on delete cascade`
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5_

  - [x] 1.2 Enable RLS and create owner-only policies on every table
    - File: `supabase/migrations/0002_rls_policies.sql`
    - For each of `users`, `user_settings`, `analyses`, `skills`, `roadmaps`: `alter table … enable row level security;` plus four policies (select/insert/update/delete) gated by `auth.uid() = user_id` (`auth.uid() = id` for `users`)
    - _Requirements: 8.6, 8.7_

  - [x] 1.3 Add the `handle_new_user` trigger that mirrors `auth.users` rows into `public.users`
    - File: `supabase/migrations/0003_handle_new_user.sql`
    - Implement the `security definer` function and the `on_auth_user_created` trigger from design.md
    - _Requirements: 2.5_

  - [x] 1.4 Write a SQL smoke test that asserts tables, columns, RLS toggles, and the four policies exist on each table
    - File: `supabase/tests/0001_schema_smoke.sql`
    - Query `information_schema.tables`, `information_schema.columns`, and `pg_policies`
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7_

- [ ] 2. FastAPI project bootstrap and core configuration
  - [x] 2.1 Initialize the Python backend project structure and dependencies
    - Files: `backend/pyproject.toml` (or `requirements.txt`), `backend/app/__init__.py`, package directories `app/core`, `app/api/v1`, `app/services`, `app/schemas`, `app/middleware`
    - Pin: `fastapi`, `uvicorn`, `pydantic`, `pydantic-settings`, `httpx`, `cryptography`, `python-jose[cryptography]`, `supabase`, `slowapi`, `pytest`, `hypothesis`, `pytest-asyncio`, `respx`
    - Add `.env.example` with `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`, `FERNET_KEYS`, `AI_MODEL_DEFAULT`, `AI_PROVIDER_BASE_URL_DEFAULT`
    - _Requirements: 9.1 (parallel for backend layout)_

  - [x] 2.2 Implement `core/config.py` and `core/supabase_client.py`
    - `Settings(BaseSettings)` class loading every env var from 2.1
    - Singleton service-role Supabase client constructed from `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`
    - _Requirements: 8.1_

  - [x] 2.3 Implement `core/security.py` for HS256 JWT verification using the Supabase secret
    - Decode + validate `exp`, `aud`, signature; raise an `InvalidToken` exception on any failure that callers translate to HTTP 401
    - _Requirements: 1.4, 1.5_

  - [x] 2.4 Property test: any malformed, missing, wrong-key, or expired JWT yields rejection
    - File: `backend/tests/property/test_security_jwt.py`
    - **Property 2: Backend rejects every malformed or missing JWT**
    - **Validates: Requirement 1.5**

  - [x] 2.5 Implement `core/encryption.py` Fernet wrapper with `MultiFernet` rotation
    - Reads `FERNET_KEYS` (comma-separated, newest first); exposes `encrypt(str) -> bytes` and `decrypt(bytes) -> str`
    - _Requirements: 6.2, 6.4_

  - [x] 2.6 Property test: AI-key ciphertext round-trips and is disjoint from plaintext
    - File: `backend/tests/property/test_encryption_roundtrip.py`
    - **Property 16: AI key encryption round-trips and never stores plaintext**
    - **Validates: Requirement 6.2**

- [ ] 3. Backend Pydantic schemas and middleware
  - [x] 3.1 Define request/response schemas
    - Files: `app/schemas/auth.py`, `app/schemas/profile.py`, `app/schemas/settings.py`, `app/schemas/analysis.py`
    - `ProfileOut`, `ProfilePatch`, `SettingsIn`, `SettingsOut`, `AnalysisRequest`, `SkillGap`, `Suggestion`, `AnalysisEnvelope`, `AnalysisResponse` exactly per design.md
    - Add HTTPS-only validators on `github_url`, `linkedin_url`, `ai_provider_base_url`
    - _Requirements: 2.3, 2.4, 6.7, 4.4, 3.3_

  - [x] 3.2 Implement `middleware/jwt_auth.py` as a FastAPI dependency
    - Reads `Authorization: Bearer <jwt>`, calls `core.security.verify`, sets `request.state.user`, raises 401 on failure
    - _Requirements: 1.3, 1.4, 1.5_

  - [x] 3.3 Implement `middleware/rate_limit.py` using `slowapi`
    - Sliding 60-second window keyed by `request.state.user.id`; default `10/minute` only on routes under `/api/v1/analysis`
    - On exceed: respond 429 with `Retry-After` set to remaining seconds in the window
    - Skip the limiter for unauthenticated requests so the JWT dependency raises 401 first
    - _Requirements: 7.1, 7.2, 7.3_

  - [x] 3.4 Property tests for the rate limiter
    - File: `backend/tests/property/test_rate_limit.py`
    - **Property 20: Sliding-window rate limit caps accepted analysis requests** — Validates Requirement 7.1
    - **Property 21: Over-limit requests return 429 with Retry-After** — Validates Requirement 7.2
    - **Property 22: Rate limiter never overrides 401 for unauthenticated requests** — Validates Requirement 7.3

- [ ] 4. Backend services
  - [x] 4.1 Implement `services/settings_service.py`
    - `get_settings(user_id) -> SettingsOut` returns only `{has_ai_key, ai_provider_base_url}` (never the key)
    - `put_settings(user_id, SettingsIn)` encrypts the key with `EncryptionService` then upserts into `user_settings`
    - `get_decrypted_key(user_id) -> str` for the analysis service; raises `MissingAIKey` if no row or null key
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6_

  - [x] 4.2 Property test that `GET /profile/settings` exposes only metadata
    - File: `backend/tests/property/test_settings_metadata.py`
    - **Property 18: GET /profile/settings exposes only metadata**
    - **Validates: Requirement 6.6**

  - [x] 4.3 Implement `services/ai_service.py` (OpenAI-compatible client + envelope validation)
    - Builds messages with the strict-schema system instruction and the user inputs verbatim
    - POSTs `{base_url}/chat/completions` via `httpx.AsyncClient` (30 s timeout) with `Authorization: Bearer <ai_key>` and `response_format={"type": "json_object"}`
    - Parses `choices[0].message.content` against `AnalysisEnvelope`; on parse/validation failure retries exactly once with a schema-reminder message
    - Translates upstream non-2xx into `UpstreamAIError(status_code, body)`; second-failure parse into `AIEnvelopeError`
    - Never calls the GitHub REST API or LinkedIn
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.8_

  - [x] 4.4 Property tests for the AI service
    - File: `backend/tests/property/test_ai_service.py`, mock upstream with `respx` / `httpx.MockTransport`
    - **Property 8: Analysis runs make exactly one outbound AI call with the user's key** — Validates Requirements 4.1, 4.2, 4.3
    - **Property 9: Every prompt enforces the analysis JSON schema** — Validates Requirement 4.4
    - **Property 10: Schema-valid AI responses round-trip to the client** — Validates Requirement 4.5
    - **Property 11: Malformed AI responses retry once and then fail with 502** — Validates Requirement 4.6
    - **Property 12: Upstream AI errors map to 502 with the upstream status echoed** — Validates Requirement 4.8

  - [x] 4.5 Implement `services/profile_service.py`
    - `get_profile(user_id) -> ProfileOut`; `patch_profile(user_id, ProfilePatch) -> ProfileOut` doing a partial update on `users`
    - First-login auto-create is handled by the DB trigger from 1.3
    - _Requirements: 2.1, 2.2, 2.3, 2.5_

  - [x] 4.6 Implement `services/analysis_service.py` orchestration + persistence fan-out
    - Fetches decrypted key + base URL via settings service; if missing, raises `MissingAIKey` → 412 `ai_key_missing`
    - Calls `ai_service.run`; on success inserts one row into `analyses` (with `result_json` = full envelope) then upserts `skills` from `skill_gaps` (unique by `(user_id, name)`) and `roadmaps` from `suggestions` (unique by `(user_id, title)`)
    - Implements `get_latest(user_id) -> AnalysisResponse | None` that returns the row with `max(created_at)`
    - _Requirements: 4.7, 5.1, 5.2, 5.3, 5.4_

  - [x] 4.7 Property tests for analysis persistence
    - File: `backend/tests/property/test_analysis_persistence.py`
    - **Property 13: Successful runs persist exactly one analyses row with matching inputs** — Validates Requirement 5.1
    - **Property 14: Skill and roadmap upserts are union-preserving** — Validates Requirements 5.2, 5.3
    - **Property 15: GET /analysis/latest returns the most recently created row** — Validates Requirement 5.4

- [ ] 5. Backend API endpoints and app wiring
  - [x] 5.1 Implement `api/v1/auth.py`
    - `POST /verify-token` returns the authenticated user record (echoes the JWT-derived identity)
    - _Requirements: 1.4, 1.5_

  - [x] 5.2 Implement `api/v1/profile.py`
    - `GET /profile/me`, `PATCH /profile/me` (writable: `github_url`, `linkedin_url`, `goal`)
    - `GET /profile/settings` returns `SettingsOut`; `PUT /profile/settings` accepts `SettingsIn` and never returns the key
    - 422 on invalid HTTPS URLs or oversize goal
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 6.1, 6.5, 6.6, 6.7_

  - [ ] 5.3 Property tests for profile endpoints
    - File: `backend/tests/property/test_profile_endpoints.py`
    - **Property 3: PATCH /profile/me is a write-then-read identity** — Validates Requirements 2.2, 2.3
    - **Property 4: Non-HTTPS profile URLs are rejected** — Validates Requirement 2.4
    - **Property 19: Non-HTTPS provider base URLs are rejected** — Validates Requirement 6.7

  - [x] 5.4 Implement `api/v1/analysis.py`
    - `POST /analysis/run` (rate-limited): calls `analysis_service.run`; maps `MissingAIKey` → 412 `ai_key_missing`, `UpstreamAIError` → 502 with `upstream_status`, `AIEnvelopeError` → 502 `ai_invalid_json`
    - `GET /analysis/latest`: returns most recent `analyses` row or 204/empty body when absent (frontend renders empty state)
    - _Requirements: 4.1, 4.5, 4.6, 4.7, 4.8, 5.1, 5.4, 5.5, 7.1_

  - [ ] 5.5 Property test that no Backend_API response body ever contains the AI key
    - File: `backend/tests/property/test_no_key_in_response.py`
    - Generates random keys with Hypothesis; asserts the substring is absent from every endpoint's serialized response
    - **Property 17: No backend response body ever contains the AI key**
    - **Validates: Requirement 6.5**

  - [x] 5.6 Wire `app/main.py`
    - Create the FastAPI app; mount `/api/v1/auth`, `/api/v1/profile`, `/api/v1/analysis` routers
    - Register the JWT dependency globally (except for `/auth/verify-token` if necessary), the slowapi limiter, and exception handlers for `InvalidToken` (401), `MissingAIKey` (412), `UpstreamAIError` (502), `AIEnvelopeError` (502), and rate-limit (429)
    - _Requirements: 1.3, 1.5, 4.7, 4.8, 7.2_

  - [ ] 5.7 End-to-end happy-path integration test
    - File: `backend/tests/integration/test_happy_path.py`
    - Boots the FastAPI app under TestClient, points the AI HTTP client at a `httpx.MockTransport` returning a canned schema-valid envelope
    - Flow: stub auth → `PATCH /profile/me` → `PUT /profile/settings` → `POST /analysis/run` → `GET /analysis/latest`
    - _Requirements: 1.4, 2.2, 4.5, 5.1, 5.4, 6.2_

- [ ] 6. Backend checkpoint
  - Ensure all backend tests pass, ask the user if questions arise.

- [x] 7. Flutter project bootstrap and core
  - [x] 7.1 Initialize the Flutter project and dependencies
    - Files: `frontend/pubspec.yaml`, `frontend/lib/main.dart`, package directories under `lib/core`, `lib/shared/widgets`, `lib/features/{auth,onboarding,dashboard}/{data,domain,presentation}`
    - Add: `flutter_riverpod`, `go_router`, `dio`, `supabase_flutter`, `flutter_animate`, `shimmer`, `mocktail` (dev), `glados` (dev)
    - _Requirements: 9.1, 9.2_

  - [x] 7.2 Implement `core/theme.dart`
    - Dark `ColorScheme` as the only theme; neon palette of cyan, purple, pink; gradient text styles spanning ≥ 2 accents
    - _Requirements: 10.1, 10.3, 10.4_

  - [x] 7.3 Implement `core/supabase_client.dart`
    - `Supabase.initialize(url, anonKey)`; expose the session stream
    - _Requirements: 1.1, 1.2_

  - [x] 7.4 Implement `core/dio_client.dart` with the JWT interceptor
    - `onRequest`: read `Supabase.instance.client.auth.currentSession?.accessToken`; attach `Authorization: Bearer <token>` for every path except `/api/v1/auth/verify-token`
    - `onError` for 401: try one `auth.refreshSession()`, retry the original request once with the new token, and on failure clear local session and route to `/login`
    - _Requirements: 1.3, 9.5, 9.6_

  - [x] 7.5 Property test for JWT attachment on every authenticated request
    - File: `frontend/test/property/dio_jwt_attach_test.dart`
    - **Property 1: Bearer JWT on every authenticated client request**
    - **Validates: Requirements 1.3, 9.5**

  - [x] 7.6 Property test for the 401 handler
    - File: `frontend/test/property/dio_401_handler_test.dart`
    - **Property 25: 401 responses clear session and route to /login**
    - **Validates: Requirement 9.6**

- [x] 8. Flutter routing and state
  - [x] 8.1 Implement `core/router.dart` with `GoRouter` and the Route_Guard redirect
    - Redirect order per design.md: no session → `/login`; missing url → `/connect`; missing goal → `/goal`; otherwise the requested route or `/dashboard`
    - _Requirements: 1.6, 3.1, 3.5, 9.3, 9.4_

  - [x] 8.2 Property tests for the Route_Guard redirect function
    - File: `frontend/test/property/route_guard_test.dart`
    - **Property 5: Incomplete onboarding always redirects to onboarding** — Validates Requirements 3.1, 9.4
    - **Property 7: Complete onboarding routes to Dashboard** — Validates Requirement 3.5
    - **Property 24: Unauthenticated navigation always lands on /login** — Validates Requirement 9.3

  - [x] 8.3 Implement Riverpod providers per design.md
    - `features/auth/presentation/providers.dart`: `authProvider` (`StreamProvider<Session?>` over Supabase auth state)
    - `features/onboarding/presentation/providers.dart`: `profileProvider` (`AsyncNotifierProvider<ProfileNotifier, Profile>` calling `/profile/me`)
    - `features/dashboard/presentation/providers.dart`: `settingsProvider`, `analysisProvider` (`FutureProvider.family`), `latestAnalysisProvider`
    - _Requirements: 9.2, 5.4, 5.5, 11.4_

- [x] 9. Flutter glassmorphism UI components
  - [x] 9.1 Implement core glassmorphism widgets
    - Files: `lib/shared/widgets/glass_card.dart` (`BackdropFilter` + translucent container), `lib/shared/widgets/gradient_text.dart` (`ShaderMask` wrapper over neon palette), `lib/shared/widgets/neon_button.dart` (outlined button with glow)
    - _Requirements: 10.2, 10.3, 10.4_

  - [x] 9.2 Implement async/visual-effect widgets
    - Files: `lib/shared/widgets/shimmer_loader.dart`, `lib/shared/widgets/animated_background.dart` (using `flutter_animate`)
    - _Requirements: 10.5, 10.6_

  - [x] 9.3 Property test that any AsyncValue.loading slot renders a ShimmerLoader
    - File: `frontend/test/property/shimmer_loading_test.dart`
    - **Property 26: Async-loading UI always renders a shimmer placeholder**
    - **Validates: Requirement 10.6**

- [ ] 10. Flutter feature screens
  - [ ] 10.1 Implement `LoginScreen`
    - File: `lib/features/auth/presentation/login_screen.dart`
    - Email + OTP step machine using Supabase `auth.signInWithOtp` then `auth.verifyOTP`; animated background; gradient heading
    - _Requirements: 1.1, 1.2, 10.4, 10.5_

  - [ ] 10.2 Implement `ConnectProfilesScreen`
    - File: `lib/features/onboarding/presentation/connect_profiles_screen.dart`
    - Two HTTPS-validated URL fields; submit calls `PATCH /profile/me`; routes onward via Route_Guard once both URLs persist
    - _Requirements: 3.1, 3.2, 2.4_

  - [ ] 10.3 Implement `SetGoalScreen`
    - File: `lib/features/onboarding/presentation/set_goal_screen.dart`
    - Text field with empty/whitespace/501-char inline validation; submit calls `PATCH /profile/me`
    - _Requirements: 3.3, 3.4, 3.5_

  - [ ] 10.4 Property test for goal validation
    - File: `frontend/test/property/set_goal_validation_test.dart`
    - **Property 6: Goal validation rejects empty and oversize input**
    - **Validates: Requirement 3.4**

  - [ ] 10.5 Implement `DashboardScreen` and its sub-views
    - Files: `lib/features/dashboard/presentation/dashboard_screen.dart`, `analysis_view.dart`, `skill_gap_view.dart`, `suggestions_view.dart`
    - Reads `latestAnalysisProvider`; renders empty state with a CTA when null; otherwise renders glassmorphism cards for `github_analysis`, `linkedin_analysis`, `skill_gaps`, `suggestions`; "Run analysis" button calls `analysisProvider`
    - On 412 `ai_key_missing` open the Settings drawer with a banner; on 429 show a snackbar with `Retry-After` countdown; on 502 show a retry CTA
    - _Requirements: 5.4, 5.5, 4.7, 7.2, 10.2, 10.5, 10.6_

  - [ ] 10.6 Implement `SettingsDrawer`
    - File: `lib/features/dashboard/presentation/settings_drawer.dart`
    - AI_Key `TextField` with `obscureText: true` and an empty controller (no pre-fill of stored key)
    - `ai_provider_base_url` field, "Key configured" indicator driven by `settings.has_ai_key`, save action calls `PUT /profile/settings`, success indicator on HTTP 200, Logout action clears the session and routes to `/login`
    - _Requirements: 1.6, 6.1, 6.6, 11.1, 11.2, 11.3, 11.4_

  - [ ] 10.7 Property tests for the Settings drawer
    - File: `frontend/test/property/settings_drawer_test.dart`
    - **Property 27: AI key input is masked and never pre-filled** — Validates Requirement 11.3
    - **Property 28: "Key configured" indicator tracks has_ai_key** — Validates Requirement 11.4

- [ ] 11. Final checkpoint
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP. They are exclusively unit, property, and integration tests.
- Property test sub-tasks each name the property number from `design.md` and the requirement clauses they validate, so traceability is one-to-one.
- The execution order — Supabase first, then FastAPI, then Flutter — is reflected in both the task numbering and the dependency graph waves below.
- Checkpoints (tasks 6 and 11) are intentionally lightweight verification gates and do not appear in the dependency graph.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1", "7.1"] },
    { "id": 1, "tasks": ["1.2", "2.2", "7.2", "7.3"] },
    { "id": 2, "tasks": ["1.3", "2.3", "2.5", "7.4"] },
    { "id": 3, "tasks": ["1.4", "2.4", "2.6", "3.1", "7.5", "7.6"] },
    { "id": 4, "tasks": ["3.2", "3.3", "8.1", "9.1", "9.2"] },
    { "id": 5, "tasks": ["3.4", "4.1", "4.3", "4.5", "8.2", "8.3", "9.3"] },
    { "id": 6, "tasks": ["4.2", "4.4", "4.6", "10.1", "10.2", "10.3"] },
    { "id": 7, "tasks": ["4.7", "5.1", "5.2", "5.4", "10.4", "10.5", "10.6"] },
    { "id": 8, "tasks": ["5.3", "5.5", "5.6", "10.7"] },
    { "id": 9, "tasks": ["5.7"] }
  ]
}
```
