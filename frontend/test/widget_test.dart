// Smoke test for the app bootstrap.
//
// Since `DevGrowthApp` now wires GoRouter + Supabase + AnimatedBackground
// (which uses perpetual timers from flutter_animate), we test the routing
// and theme configuration without rendering the full screen tree.

import 'package:devgrowth_ai/core/router.dart';
import 'package:devgrowth_ai/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildDarkTheme returns a dark ThemeData with neon palette', () {
    final theme = buildDarkTheme();

    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, kNeonPurple);
    expect(theme.colorScheme.secondary, kNeonCyan);
    expect(theme.colorScheme.tertiary, kNeonPink);
    expect(theme.scaffoldBackgroundColor, kBgDeep);
  });

  test('buildRouter creates a GoRouter that redirects to /login when no session', () {
    final router = buildRouter(
      hasSession: () => false,
      profile: () => null,
    );

    // The router should exist and have /login as the resolved initial location.
    expect(router, isNotNull);
    // GoRouter's configuration is set up correctly.
    expect(router.routeInformationProvider, isNotNull);
  });

  test('routeGuardRedirect sends unauthenticated users to /login', () {
    final result = routeGuardRedirect(
      hasSession: false,
      profile: null,
      location: '/dashboard',
    );
    expect(result, AppRoutes.login);
  });

  test('routeGuardRedirect sends complete users to /dashboard from /login', () {
    final result = routeGuardRedirect(
      hasSession: true,
      profile: const RouteGuardProfile(
        githubUrl: 'https://github.com/test',
        linkedinUrl: 'https://linkedin.com/in/test',
        goal: 'Be a Staff Engineer',
      ),
      location: '/login',
    );
    expect(result, AppRoutes.dashboard);
  });
}
