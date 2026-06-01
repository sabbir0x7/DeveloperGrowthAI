# Requirements Document

## Introduction

DevGrowth AI is an AI-powered career growth platform for software developers. Users authenticate via Supabase OTP, connect their public developer profiles (GitHub and LinkedIn URLs), set a career goal, and receive an AI-generated analysis containing profile summaries, skill gap analysis, and growth suggestions. The platform consists of a FastAPI backend, a Flutter frontend (Web and Mobile), and a Supabase Postgres database. AI inference is delegated to any OpenAI-compatible chat completions endpoint configured by the user.

The system delivers value through a single conversational pipeline: rather than scraping external APIs, the backend forwards user-provided URLs and goals directly to a Large Language Model under a strict JSON schema, persists the structured response, and renders it in a dark-themed dashboard with glassmorphism styling.

## Glossary

- **DevGrowth_System**: The complete platform comprising the FastAPI backend, Flutter frontend, and Supabase database.
- **Backend_API**: The FastAPI service exposing endpoints under the base path `/api/v1`.
- **Frontend_App**: The Flutter application running on Web and Mobile targets.
- **Auth_Service**: The backend module responsible for verifying Supabase-issued JWT tokens.
- **Profile_Service**: The backend module responsible for reading and updating user profile records.
- **Analysis_Service**: The backend module responsible for orchestrating AI analysis runs and persisting results.
- **AI_Client**: The backend HTTP client that calls an OpenAI-compatible `/chat/completions` endpoint.
- **Settings_Service**: The backend module responsible for storing and retrieving each user's encrypted AI API key and provider base URL.
- **Rate_Limiter**: The backend middleware enforcing per-user request quotas on analysis endpoints.
- **Database**: The Supabase Postgres instance hosting `users`, `user_settings`, `analyses`, `skills`, and `roadmaps` tables.
- **RLS**: Row-Level Security policies enforced by Supabase Postgres.
- **OTP**: One-Time Password sent by Supabase Auth for passwordless login.
- **JWT**: JSON Web Token issued by Supabase Auth and accepted by the Backend_API.
- **AI_Key**: An OpenAI-compatible API key supplied by the user (e.g., OpenAI, Groq, OpenRouter).
- **Provider_Base_URL**: The base URL of the OpenAI-compatible service the AI_Client targets (default `https://api.openai.com/v1`).
- **Analysis_Result**: A structured JSON object containing `github_analysis`, `linkedin_analysis`, `skill_gaps`, and `suggestions`.
- **Goal**: A free-text career objective set by the user (e.g., "Become a Senior Backend Engineer").
- **Route_Guard**: A GoRouter redirect that gates navigation based on authentication and profile state.

## Requirements

### Requirement 1: Authentication via Supabase OTP

**User Story:** As a developer, I want to log in using a one-time password sent to my email, so that I can access the platform without managing a password.

#### Acceptance Criteria

1. WHEN a user submits an email address from the login screen, THE Frontend_App SHALL invoke Supabase Auth to send an OTP to the submitted address.
2. WHEN a user submits a valid OTP code, THE Frontend_App SHALL receive a Supabase JWT and store the JWT in secure local storage.
3. WHEN the Frontend_App calls any Backend_API endpoint other than `/auth/verify-token`, THE Frontend_App SHALL include the JWT in the `Authorization: Bearer <token>` header.
4. WHEN the Backend_API receives a request to `POST /api/v1/auth/verify-token` with a valid Supabase JWT, THE Auth_Service SHALL return the authenticated user record.
5. IF the Backend_API receives a request with a missing, expired, or invalid JWT, THEN THE Auth_Service SHALL respond with HTTP status 401.
6. WHEN a user selects "Logout" from the settings drawer, THE Frontend_App SHALL clear the stored JWT and redirect to the login screen.

### Requirement 2: User Profile Management

**User Story:** As an authenticated user, I want to view and update my profile information, so that the platform reflects my current details.

#### Acceptance Criteria

1. WHEN the Frontend_App calls `GET /api/v1/profile/me` with a valid JWT, THE Profile_Service SHALL return the authenticated user's profile fields.
2. WHEN the Frontend_App calls `PATCH /api/v1/profile/me` with a valid JWT and a JSON body containing one or more updatable fields, THE Profile_Service SHALL persist the changes and return the updated profile.
3. THE Profile_Service SHALL accept `github_url`, `linkedin_url`, and `goal` as updatable fields on `PATCH /api/v1/profile/me`.
4. IF a `PATCH /api/v1/profile/me` request includes a `github_url` or `linkedin_url` that is not a syntactically valid HTTPS URL, THEN THE Profile_Service SHALL respond with HTTP status 422 and a field-level error message.
5. WHEN a new user authenticates for the first time, THE Profile_Service SHALL create a corresponding row in the `users` table linked to the Supabase auth user ID.

### Requirement 3: Profile Connection and Goal Onboarding

**User Story:** As a new user, I want to connect my GitHub and LinkedIn profiles and set a career goal, so that the AI has the inputs it needs to generate an analysis.

#### Acceptance Criteria

1. WHEN an authenticated user with no `github_url`, `linkedin_url`, or `goal` set navigates to any protected route, THE Frontend_App SHALL redirect the user to the Connect Profiles screen via a Route_Guard.
2. WHEN a user submits the Connect Profiles form with a GitHub URL and a LinkedIn URL, THE Frontend_App SHALL persist the URLs by calling `PATCH /api/v1/profile/me`.
3. WHEN a user submits the Set Goal screen with a non-empty goal string of at most 500 characters, THE Frontend_App SHALL persist the goal by calling `PATCH /api/v1/profile/me`.
4. IF a user submits the Set Goal screen with an empty string or a string longer than 500 characters, THEN THE Frontend_App SHALL display an inline validation error and SHALL NOT call the Backend_API.
5. WHEN a user has both URLs and a goal persisted, THE Frontend_App SHALL route the user to the Dashboard.

### Requirement 4: AI Analysis Run

**User Story:** As an onboarded user, I want the platform to analyze my profiles and goal using AI, so that I receive personalized growth insights.

#### Acceptance Criteria

1. WHEN the Frontend_App calls `POST /api/v1/analysis/run` with a JSON body `{ github_url, linkedin_url, goal }` and a valid JWT, THE Analysis_Service SHALL load the requesting user's encrypted AI_Key from the Database, decrypt the AI_Key in memory, and invoke the AI_Client.
2. THE Analysis_Service SHALL pass the `github_url`, `linkedin_url`, and `goal` values into the AI prompt as the sole data inputs and SHALL NOT call the GitHub REST API or scrape LinkedIn.
3. THE AI_Client SHALL target the user's Provider_Base_URL using the OpenAI-compatible `POST /chat/completions` contract and SHALL send the AI_Key in the `Authorization: Bearer <key>` header.
4. THE Analysis_Service SHALL instruct the AI to respond with JSON conforming to the schema `{ github_analysis: object, linkedin_analysis: object, skill_gaps: array, suggestions: array }`.
5. WHEN the AI returns a response that successfully parses against the Analysis_Result schema, THE Analysis_Service SHALL return the parsed object to the Frontend_App with HTTP status 200.
6. IF the AI response cannot be parsed against the Analysis_Result schema after one retry, THEN THE Analysis_Service SHALL respond with HTTP status 502 and an error message identifying the schema validation failure.
7. IF the requesting user has no AI_Key configured, THEN THE Analysis_Service SHALL respond with HTTP status 412 and an error code `ai_key_missing`.
8. WHEN the AI_Client receives an HTTP error response from the upstream provider, THE Analysis_Service SHALL respond with HTTP status 502 and SHALL include the upstream status code in the error payload.

### Requirement 5: Analysis Persistence and Caching

**User Story:** As a returning user, I want my latest analysis to load instantly on the dashboard, so that I do not have to wait for a new AI run on every visit.

#### Acceptance Criteria

1. WHEN the Analysis_Service produces a valid Analysis_Result, THE Analysis_Service SHALL insert a new row into the `analyses` table containing the user ID, the input goal, the input URLs, the raw JSON Analysis_Result, and a creation timestamp.
2. WHEN the Analysis_Service produces a valid Analysis_Result, THE Analysis_Service SHALL upsert each entry in `skill_gaps` into the `skills` table linked to the user.
3. WHEN the Analysis_Service produces a valid Analysis_Result, THE Analysis_Service SHALL upsert each entry in `suggestions` into the `roadmaps` table linked to the user.
4. WHEN the Frontend_App loads the Dashboard, THE Frontend_App SHALL call a Backend_API endpoint that returns the most recent `analyses` row for the authenticated user.
5. WHEN no `analyses` row exists for the authenticated user, THE Frontend_App SHALL display the empty-state Dashboard with a call to action to run the first analysis.

### Requirement 6: AI Key Storage and Encryption

**User Story:** As a privacy-conscious user, I want my AI API key encrypted at rest and never replayed by the client, so that my key remains secure.

#### Acceptance Criteria

1. WHEN a user saves an AI_Key from the Settings drawer, THE Frontend_App SHALL submit the AI_Key and Provider_Base_URL to the Backend_API over HTTPS.
2. WHEN the Settings_Service receives an AI_Key, THE Settings_Service SHALL encrypt the AI_Key using Fernet symmetric encryption with a server-side key before persisting it in the `user_settings` table.
3. THE Settings_Service SHALL store the Provider_Base_URL as plaintext in the `user_settings` table.
4. WHEN the Analysis_Service requires the AI_Key for an analysis run, THE Settings_Service SHALL fetch the encrypted record and decrypt the AI_Key in memory for the duration of the request.
5. THE Backend_API SHALL NOT return the decrypted AI_Key in any response body.
6. WHEN the Frontend_App requests the user's settings, THE Settings_Service SHALL return a boolean `has_ai_key` flag and the Provider_Base_URL but SHALL NOT return the AI_Key.
7. IF a user submits a Provider_Base_URL that is not a syntactically valid HTTPS URL, THEN THE Settings_Service SHALL respond with HTTP status 422.

### Requirement 7: Rate Limiting on Analysis Endpoints

**User Story:** As a platform operator, I want to cap analysis traffic per user, so that AI provider costs and abuse risks remain bounded.

#### Acceptance Criteria

1. WHEN a user sends requests to any path matching `/api/v1/analysis/*`, THE Rate_Limiter SHALL count requests in a sliding 60-second window keyed by the authenticated user ID.
2. IF a user exceeds 10 requests within a 60-second window on `/api/v1/analysis/*`, THEN THE Rate_Limiter SHALL respond with HTTP status 429 and a `Retry-After` header indicating the seconds until the window resets.
3. THE Rate_Limiter SHALL apply only to authenticated requests and SHALL allow unauthenticated requests to fall through to the Auth_Service for 401 handling.

### Requirement 8: Database Schema and Row-Level Security

**User Story:** As a security engineer, I want every table protected by RLS, so that one user can never read or modify another user's data.

#### Acceptance Criteria

1. THE Database SHALL define tables `users`, `user_settings`, `analyses`, `skills`, and `roadmaps`.
2. THE `user_settings` table SHALL contain columns `user_id`, `encrypted_ai_key`, `ai_provider_base_url`, `created_at`, and `updated_at`.
3. THE `analyses` table SHALL contain columns `id`, `user_id`, `goal`, `github_url`, `linkedin_url`, `result_json`, and `created_at`.
4. THE `skills` table SHALL contain at minimum `id`, `user_id`, `name`, `gap_level`, and `updated_at`.
5. THE `roadmaps` table SHALL contain at minimum `id`, `user_id`, `title`, `description`, `priority`, and `updated_at`.
6. THE Database SHALL enable RLS on `users`, `user_settings`, `analyses`, `skills`, and `roadmaps`.
7. THE Database SHALL define RLS policies on each of those tables that permit `SELECT`, `INSERT`, `UPDATE`, and `DELETE` only when `auth.uid() = user_id`.

### Requirement 9: Frontend Architecture and Routing

**User Story:** As a developer maintaining the Flutter app, I want a feature-based architecture with route guards and a typed HTTP client, so that the codebase is consistent and authentication state is enforced uniformly.

#### Acceptance Criteria

1. THE Frontend_App SHALL organize source code under `lib/features/<feature_name>/` directories with `data`, `domain`, and `presentation` subfolders per feature.
2. THE Frontend_App SHALL manage state using Riverpod providers.
3. THE Frontend_App SHALL declare routes using GoRouter and SHALL define a Route_Guard that redirects unauthenticated requests to the login screen.
4. THE Frontend_App SHALL define a Route_Guard that redirects authenticated users with incomplete onboarding to the Connect Profiles or Set Goal screen.
5. THE Frontend_App SHALL configure a Dio HTTP client with an interceptor that attaches the stored JWT to every outgoing request.
6. WHEN the Dio interceptor receives an HTTP 401 response, THE Frontend_App SHALL clear the stored JWT and redirect to the login screen.

### Requirement 10: Visual Design System

**User Story:** As a user, I want a consistent dark-themed visual experience with glassmorphism and neon accents, so that the product feels modern and on-brand.

#### Acceptance Criteria

1. THE Frontend_App SHALL render every screen using a dark color palette as the default and only theme.
2. THE Frontend_App SHALL render primary content containers as glassmorphism cards with translucent backgrounds and blurred backdrops.
3. THE Frontend_App SHALL apply neon accent colors drawn from the set {cyan, purple, pink} to interactive elements and highlights.
4. THE Frontend_App SHALL render top-level page headings with a gradient fill spanning at least two of the neon accent colors.
5. THE Frontend_App SHALL render an animated background on the login, onboarding, and dashboard screens.
6. WHILE an asynchronous data load is in progress, THE Frontend_App SHALL display shimmer placeholder components in place of the pending content.

### Requirement 11: Settings Drawer

**User Story:** As an authenticated user, I want a settings drawer where I can manage my AI key and log out, so that I can control account configuration without leaving the dashboard.

#### Acceptance Criteria

1. WHEN an authenticated user opens the settings drawer, THE Frontend_App SHALL display a field for the AI_Key, a field for the Provider_Base_URL, and a Logout action.
2. WHEN the user saves the AI_Key field, THE Frontend_App SHALL submit the value to the Backend_API and SHALL display a success indicator on HTTP 200.
3. THE Frontend_App SHALL render the AI_Key input as a masked field and SHALL NOT display the previously stored AI_Key value.
4. WHEN the Frontend_App receives a `has_ai_key = true` response from the Settings_Service, THE Frontend_App SHALL render a "Key configured" indicator next to the AI_Key field.
