/// GoRouter configuration and Route_Guard redirect.
///
/// This module owns the app's [GoRouter] instance and the pure redirect
/// function that enforces the auth + onboarding state machine described in
/// `design.md`:
///
/// 1. `session == null`              → `/login`
/// 2. `github_url == null || linkedin_url == null` → `/connect`
/// 3. `goal == null`                 → `/goal`
/// 4. otherwise                      → the requested route, defaulting to
///                                     `/dashboard`
///
/// The redirect is implemented as a top-level pure function,
/// [routeGuardRedirect], so the property tests in
/// `frontend/test/property/route_guard_test.dart` (task 8.2) can exercise
/// it without booting a full router/Riverpod tree. The [buildRouter]
/// factory wires that pure function into a real [GoRouter] together with
/// a [Listenable] that the caller (task 8.3 providers) uses to trigger
/// re-evaluation when the auth or profile state changes.
///
/// The screens referenced here are placeholder widgets except for
/// [AppRoutes.goal], which renders the real `SetGoalScreen` from task
/// 10.3. Real implementations of the other screens land in tasks 10.1,
/// 10.2, and 10.5; those tasks can replace the placeholder builders
/// while keeping the routing configuration intact.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/presentation/login_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/dashboard/presentation/setup_key_screen.dart';
import '../features/onboarding/presentation/connect_profiles_screen.dart';
import '../features/onboarding/presentation/set_goal_screen.dart';

/// Canonical route paths used throughout the app.
///
/// Route values are exposed as `static const` strings so feature code
/// can `context.go(AppRoutes.dashboard)` without stringly-typed paths
/// scattered around the codebase.
class AppRoutes {
  AppRoutes._();

  /// Email + OTP login screen.
  static const String login = '/login';

  /// Onboarding step 1 — collect GitHub and LinkedIn URLs.
  static const String connect = '/connect';

  /// Onboarding step 2 — collect the user's career goal.
  static const String goal = '/goal';

  /// Onboarding step 3 — configure AI key before first analysis.
  static const String setupKey = '/setup-key';

  /// The signed-in landing page; reads the latest analysis.
  static const String dashboard = '/dashboard';
}

/// The two onboarding routes the Route_Guard treats as a single zone.
///
/// When onboarding is complete and the user lands on either of these,
/// the guard pushes them forward to [AppRoutes.dashboard].
const Set<String> _kOnboardingRoutes = <String>{
  AppRoutes.connect,
  AppRoutes.goal,
  AppRoutes.setupKey,
};

/// Minimal slice of the user's profile that the Route_Guard needs.
///
/// The full `Profile` model lives under `features/onboarding/domain/`
/// and is owned by task 8.3. The guard only cares about whether the
/// three onboarding fields are present, so we expose this small,
/// router-local value type to keep `core/router.dart` independent of
/// feature code.
@immutable
class RouteGuardProfile {
  /// Creates a guard profile snapshot.
  ///
  /// All fields default to `null`, modelling a freshly-authenticated
  /// user whose profile row has not been loaded or filled in yet.
  const RouteGuardProfile({
    this.githubUrl,
    this.linkedinUrl,
    this.goal,
    this.hasAiKey = false,
  });

  /// The user's GitHub profile URL, or `null` if not yet set.
  final String? githubUrl;

  /// The user's LinkedIn profile URL, or `null` if not yet set.
  final String? linkedinUrl;

  /// The user's free-text career goal, or `null` if not yet set.
  final String? goal;

  /// Whether the user has configured an AI key.
  final bool hasAiKey;

  /// True when both onboarding URLs are present.
  bool get hasUrls => githubUrl != null && linkedinUrl != null;

  /// True when the goal field is present.
  bool get hasGoal => goal != null;

  /// True when every onboarding field is filled in (including AI key).
  bool get isComplete => hasUrls && hasGoal && hasAiKey;
}

/// Pure Route_Guard redirect.
///
/// Returns the path the router should redirect to, or `null` to allow
/// the requested [location] to resolve as-is.
///
/// The decision order matches the state diagram in `design.md`:
///
/// 1. If [hasSession] is `false`, redirect any non-`/login` location to
///    `/login`. Already on `/login` resolves to `null`.
/// 2. If signed in but [profile] has a missing URL, redirect any
///    non-`/connect` location to `/connect`.
/// 3. If signed in with both URLs but no goal, redirect any non-`/goal`
///    location to `/goal`.
/// 4. If signed in and onboarding is complete, redirect any onboarding
///    or `/login` route to `/dashboard`; otherwise allow the requested
///    route.
///
/// A `null` [profile] is treated as "all fields missing" so a
/// freshly-authenticated user with no profile row yet still flows into
/// `/connect`. This matches Property 5 in `design.md` (incomplete
/// onboarding always redirects to onboarding) and avoids leaking the
/// dashboard during the brief window between sign-in and the first
/// `GET /profile/me` response.
///
/// **Validates: Requirements 1.6, 3.1, 3.5, 9.3, 9.4**
String? routeGuardRedirect({
  required bool hasSession,
  required RouteGuardProfile? profile,
  required String location,
}) {
  // Step 1: unauthenticated → /login.
  if (!hasSession) {
    if (location == AppRoutes.login) {
      return null;
    }
    return AppRoutes.login;
  }

  // From here on the user is authenticated. A null profile is treated
  // as "all fields missing"; see the doc-comment above.
  final RouteGuardProfile snapshot = profile ?? const RouteGuardProfile();

  // Authenticated users never stay on /login. Forward them to the
  // earliest unfinished step, or to /dashboard when complete.
  if (location == AppRoutes.login) {
    if (!snapshot.hasAiKey) {
      return AppRoutes.setupKey;
    }
    if (!snapshot.hasUrls) {
      return AppRoutes.connect;
    }
    if (!snapshot.hasGoal) {
      return AppRoutes.goal;
    }
    return AppRoutes.dashboard;
  }

  // Step 2: missing AI key → /setup-key.
  if (!snapshot.hasAiKey) {
    if (location == AppRoutes.setupKey) {
      return null;
    }
    return AppRoutes.setupKey;
  }

  // Step 3: missing url(s) → /connect.
  if (!snapshot.hasUrls) {
    if (location == AppRoutes.connect) {
      return null;
    }
    return AppRoutes.connect;
  }

  // Step 4: urls present, missing goal → /goal.
  if (!snapshot.hasGoal) {
    if (location == AppRoutes.goal) {
      return null;
    }
    return AppRoutes.goal;
  }

  // Step 5: onboarding complete. If the user landed on an onboarding
  // route, push them to /dashboard. Otherwise allow the requested route.
  if (_kOnboardingRoutes.contains(location)) {
    return AppRoutes.dashboard;
  }
  return null;
}

/// Reads `true` when a Supabase session currently exists.
typedef HasSessionGetter = bool Function();

/// Reads the latest [RouteGuardProfile] snapshot, or `null` when the
/// profile has not yet been loaded.
typedef RouteGuardProfileGetter = RouteGuardProfile? Function();

/// Builds the configured [GoRouter] for the app.
///
/// [hasSession] and [profile] are read on every redirect evaluation so
/// the router always sees the freshest auth/onboarding state. The
/// [refreshListenable] should fire whenever either signal changes
/// (typically a `Listenable` derived from the `authProvider` and
/// `profileProvider` Riverpod providers added in task 8.3).
///
/// [initialLocation] defaults to `/login`; the redirect will forward
/// the user from there to the correct screen on the first frame.
GoRouter buildRouter({
  required HasSessionGetter hasSession,
  required RouteGuardProfileGetter profile,
  Listenable? refreshListenable,
  String initialLocation = AppRoutes.login,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: refreshListenable,
    redirect: (BuildContext context, GoRouterState state) {
      return routeGuardRedirect(
        hasSession: hasSession(),
        profile: profile(),
        location: state.matchedLocation,
      );
    },
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        builder: (BuildContext context, GoRouterState state) =>
            const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.connect,
        name: 'connect',
        builder: (BuildContext context, GoRouterState state) =>
            const ConnectProfilesScreen(),
      ),
      GoRoute(
        path: AppRoutes.goal,
        name: 'goal',
        builder: (BuildContext context, GoRouterState state) =>
            const SetGoalScreen(),
      ),
      GoRoute(
        path: AppRoutes.setupKey,
        name: 'setup-key',
        builder: (BuildContext context, GoRouterState state) =>
            const SetupKeyScreen(),
      ),
      GoRoute(
        path: AppRoutes.dashboard,
        name: 'dashboard',
        builder: (BuildContext context, GoRouterState state) =>
            const DashboardScreen(),
      ),
    ],
  );
}
