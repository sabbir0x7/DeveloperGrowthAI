/// Property tests for the Route_Guard redirect function.
///
/// Exercises the pure [routeGuardRedirect] function from
/// `lib/core/router.dart` across many randomized auth + profile snapshots
/// so the three redirect properties from `design.md` hold for any input.
///
/// **Property 5 — Incomplete onboarding always redirects to onboarding.**
///   For any authenticated session whose profile has `githubUrl == null`,
///   `linkedinUrl == null`, or `goal == null`, navigation to any route
///   resolves through the guard to `/connect` (when a URL is missing) or
///   `/goal` (when only the goal is missing).
///   **Validates: Requirements 3.1, 9.4**
///
/// **Property 7 — Complete onboarding routes to Dashboard.**
///   For any authenticated session whose profile has non-null
///   `githubUrl`, `linkedinUrl`, and `goal`, navigation to any non-auth
///   route resolves through the guard to `/dashboard` unless the user
///   explicitly requested another (non-auth, non-onboarding) protected
///   route.
///   **Validates: Requirement 3.5**
///
/// **Property 24 — Unauthenticated navigation always lands on /login.**
///   For any application route in any state where the session is absent,
///   the GoRouter Route_Guard resolves the navigation to `/login`.
///   **Validates: Requirement 9.3**
library;

import 'dart:math';

import 'package:devgrowth_ai/core/router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Number of random iterations per property. The design doc requires
/// each property test to run at least 100 iterations.
const int _iterations = 100;

/// Routes the guard treats as "auth/onboarding" zones; complete users
/// are pushed off them onto `/dashboard`.
const Set<String> _authOrOnboardingRoutes = <String>{
  AppRoutes.login,
  AppRoutes.connect,
  AppRoutes.goal,
};

/// Pool of realistic concrete locations the router might receive.
const List<String> _knownRoutes = <String>[
  AppRoutes.login,
  AppRoutes.connect,
  AppRoutes.goal,
  AppRoutes.dashboard,
];

/// Resolves the final location the router would land on after one
/// redirect pass: returns the redirect target if the guard produced one,
/// or the original [location] otherwise.
///
/// All properties below talk about "the route the user lands on", which
/// is exactly this resolved value.
String _resolved(String? redirectTarget, String location) =>
    redirectTarget ?? location;

/// Generates a random URL-shaped string. Non-empty by construction so
/// the guard treats it as "set".
String _randomUrl(Random rng) {
  final int length = 8 + rng.nextInt(40);
  final StringBuffer buf = StringBuffer('https://');
  for (int i = 0; i < length; i++) {
    buf.write(_urlAlphabet[rng.nextInt(_urlAlphabet.length)]);
  }
  return buf.toString();
}

/// Generates a random non-empty goal string.
String _randomGoal(Random rng) {
  final int length = 1 + rng.nextInt(120);
  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < length; i++) {
    buf.write(_goalAlphabet[rng.nextInt(_goalAlphabet.length)]);
  }
  return buf.toString();
}

/// Generates a random "other" route the router might be asked to render.
/// Mixes the known routes with completely random paths and absolute URLs
/// so the property holds across the full open input space.
String _randomLocation(Random rng) {
  final int branch = rng.nextInt(4);
  switch (branch) {
    case 0:
      return _knownRoutes[rng.nextInt(_knownRoutes.length)];
    case 1:
      // Random absolute path.
      final int segs = 1 + rng.nextInt(3);
      final StringBuffer buf = StringBuffer();
      for (int i = 0; i < segs; i++) {
        buf.write('/');
        final int len = 1 + rng.nextInt(10);
        for (int j = 0; j < len; j++) {
          buf.write(_urlAlphabet[rng.nextInt(_urlAlphabet.length)]);
        }
      }
      return buf.toString();
    case 2:
      // Empty, root, or just slashes — exercises edge inputs.
      return rng.nextBool() ? '/' : '';
    default:
      // Anything goes (including non-path strings).
      final int len = 1 + rng.nextInt(20);
      final StringBuffer buf = StringBuffer();
      for (int i = 0; i < len; i++) {
        buf.write(_urlAlphabet[rng.nextInt(_urlAlphabet.length)]);
      }
      return buf.toString();
  }
}

/// Generates an incomplete profile where at least one of `githubUrl`,
/// `linkedinUrl`, `goal` is `null`. Returns `null` itself with some
/// probability to model "profile not yet loaded".
RouteGuardProfile? _randomIncompleteProfile(Random rng) {
  // 1-in-5: model the "profile row not loaded yet" case as null.
  if (rng.nextInt(5) == 0) {
    return null;
  }
  // Pick at least one missing field. We encode the three booleans
  // (githubMissing, linkedinMissing, goalMissing) as a 1..7 bitmask so
  // every non-zero combination is possible.
  final int mask = 1 + rng.nextInt(7);
  final bool githubMissing = (mask & 0x1) != 0;
  final bool linkedinMissing = (mask & 0x2) != 0;
  final bool goalMissing = (mask & 0x4) != 0;
  return RouteGuardProfile(
    githubUrl: githubMissing ? null : _randomUrl(rng),
    linkedinUrl: linkedinMissing ? null : _randomUrl(rng),
    goal: goalMissing ? null : _randomGoal(rng),
  );
}

/// Generates a complete profile (every field non-null).
RouteGuardProfile _randomCompleteProfile(Random rng) => RouteGuardProfile(
      githubUrl: _randomUrl(rng),
      linkedinUrl: _randomUrl(rng),
      goal: _randomGoal(rng),
    );

// URL-shaped characters: letters, digits, dashes, dots, slashes.
const String _urlAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-./';

// Goal characters: letters, digits, spaces, common punctuation.
const String _goalAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?-';

void main() {
  group('Property 24: Unauthenticated navigation always lands on /login', () {
    test(
        'for any location, hasSession=false resolves to /login regardless '
        'of profile state', () {
      final Random rng = Random(0xA17B0001);

      for (int i = 0; i < _iterations; i++) {
        final String location = _randomLocation(rng);
        // Profile state must be irrelevant when there is no session.
        final RouteGuardProfile? profile = rng.nextBool()
            ? null
            : (rng.nextBool()
                ? _randomCompleteProfile(rng)
                : _randomIncompleteProfile(rng));

        final String? redirect = routeGuardRedirect(
          hasSession: false,
          profile: profile,
          location: location,
        );
        final String landing = _resolved(redirect, location);

        expect(
          landing,
          equals(AppRoutes.login),
          reason: 'iteration $i: hasSession=false, location="$location", '
              'profile=$profile must resolve to /login (got "$landing")',
        );
      }
    });

    test(
        'when location is already /login and there is no session, the '
        'guard yields null (no further redirect)', () {
      final Random rng = Random(0xA17B0002);

      for (int i = 0; i < _iterations; i++) {
        final RouteGuardProfile? profile = rng.nextBool()
            ? null
            : (rng.nextBool()
                ? _randomCompleteProfile(rng)
                : _randomIncompleteProfile(rng));

        final String? redirect = routeGuardRedirect(
          hasSession: false,
          profile: profile,
          location: AppRoutes.login,
        );

        expect(
          redirect,
          isNull,
          reason: 'iteration $i: hasSession=false on /login should not '
              'produce a self-redirect (got "$redirect")',
        );
      }
    });
  });

  group('Property 5: Incomplete onboarding always redirects to onboarding',
      () {
    test(
        'authenticated + missing url(s) ⇒ resolves to /connect; '
        'urls present + missing goal ⇒ resolves to /goal', () {
      final Random rng = Random(0xB0AC0003);

      for (int i = 0; i < _iterations; i++) {
        final RouteGuardProfile? profile = _randomIncompleteProfile(rng);
        final String location = _randomLocation(rng);

        final String? redirect = routeGuardRedirect(
          hasSession: true,
          profile: profile,
          location: location,
        );
        final String landing = _resolved(redirect, location);

        // Treat a null profile snapshot as "all fields missing", matching
        // the doc-comment contract on routeGuardRedirect.
        final RouteGuardProfile snapshot =
            profile ?? const RouteGuardProfile();

        final String expected = !snapshot.hasUrls
            ? AppRoutes.connect
            : AppRoutes.goal;

        expect(
          landing,
          equals(expected),
          reason: 'iteration $i: incomplete profile '
              '(github=${snapshot.githubUrl}, linkedin=${snapshot.linkedinUrl}, '
              'goal=${snapshot.goal}) at location "$location" must resolve '
              'to "$expected" (got "$landing")',
        );
      }
    });

    test(
        'on /connect with a missing url, the guard yields null '
        '(already at the right onboarding step)', () {
      final Random rng = Random(0xB0AC0004);

      for (int i = 0; i < _iterations; i++) {
        // Force at least one URL missing so /connect is the correct step.
        final bool githubMissing = rng.nextBool();
        final bool linkedinMissing = !githubMissing || rng.nextBool();
        final RouteGuardProfile profile = RouteGuardProfile(
          githubUrl: githubMissing ? null : _randomUrl(rng),
          linkedinUrl: linkedinMissing ? null : _randomUrl(rng),
          goal: rng.nextBool() ? null : _randomGoal(rng),
        );

        final String? redirect = routeGuardRedirect(
          hasSession: true,
          profile: profile,
          location: AppRoutes.connect,
        );

        expect(
          redirect,
          isNull,
          reason: 'iteration $i: /connect with missing url(s) '
              '($profile) must not redirect again (got "$redirect")',
        );
      }
    });

    test(
        'on /goal with both urls present and goal missing, the guard '
        'yields null (already at the right onboarding step)', () {
      final Random rng = Random(0xB0AC0005);

      for (int i = 0; i < _iterations; i++) {
        final RouteGuardProfile profile = RouteGuardProfile(
          githubUrl: _randomUrl(rng),
          linkedinUrl: _randomUrl(rng),
          goal: null,
        );

        final String? redirect = routeGuardRedirect(
          hasSession: true,
          profile: profile,
          location: AppRoutes.goal,
        );

        expect(
          redirect,
          isNull,
          reason: 'iteration $i: /goal with urls set + goal null '
              '($profile) must not redirect again (got "$redirect")',
        );
      }
    });
  });

  group('Property 7: Complete onboarding routes to Dashboard', () {
    test(
        'authenticated + complete profile on any auth/onboarding route '
        'resolves to /dashboard', () {
      final Random rng = Random(0xC0DE0006);

      for (int i = 0; i < _iterations; i++) {
        final RouteGuardProfile profile = _randomCompleteProfile(rng);
        final String location = _authOrOnboardingRoutes
            .elementAt(rng.nextInt(_authOrOnboardingRoutes.length));

        final String? redirect = routeGuardRedirect(
          hasSession: true,
          profile: profile,
          location: location,
        );
        final String landing = _resolved(redirect, location);

        expect(
          landing,
          equals(AppRoutes.dashboard),
          reason: 'iteration $i: complete profile on "$location" must '
              'resolve to /dashboard (got "$landing")',
        );
      }
    });

    test(
        'authenticated + complete profile on a non-auth, non-onboarding '
        'route preserves the requested route (guard yields null)', () {
      final Random rng = Random(0xC0DE0007);

      int checked = 0;
      while (checked < _iterations) {
        final String location = _randomLocation(rng);
        // Skip the auth/onboarding zone — that branch is covered above.
        if (_authOrOnboardingRoutes.contains(location)) {
          continue;
        }
        final RouteGuardProfile profile = _randomCompleteProfile(rng);

        final String? redirect = routeGuardRedirect(
          hasSession: true,
          profile: profile,
          location: location,
        );

        expect(
          redirect,
          isNull,
          reason: 'iteration $checked: complete profile on non-auth '
              'route "$location" must not redirect (got "$redirect")',
        );
        checked++;
      }
    });

    test(
        'authenticated + complete profile on /dashboard yields null '
        '(no self-redirect)', () {
      final Random rng = Random(0xC0DE0008);

      for (int i = 0; i < _iterations; i++) {
        final RouteGuardProfile profile = _randomCompleteProfile(rng);

        final String? redirect = routeGuardRedirect(
          hasSession: true,
          profile: profile,
          location: AppRoutes.dashboard,
        );

        expect(
          redirect,
          isNull,
          reason: 'iteration $i: /dashboard with complete profile '
              '($profile) must not self-redirect (got "$redirect")',
        );
      }
    });
  });
}
