/// Smoke test for the Riverpod providers added in task 8.3.
///
/// This is intentionally a lightweight wiring test: it verifies the
/// provider declarations type-check, can be imported, and that the
/// derived router providers behave correctly without booting Supabase
/// or Dio. The full property-based coverage of provider behavior lands
/// in tasks 8.2, 7.5, 7.6, 9.3, 10.4, and 10.7.
library;

import 'package:devgrowth_ai/core/router.dart' show RouteGuardProfile;
import 'package:devgrowth_ai/features/auth/presentation/providers.dart';
import 'package:devgrowth_ai/features/dashboard/presentation/providers.dart';
import 'package:devgrowth_ai/features/onboarding/domain/profile.dart';
import 'package:devgrowth_ai/features/onboarding/presentation/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Riverpod providers smoke', () {
    test('auth, profile, settings, analysis, latestAnalysis are declared', () {
      // Touching the symbols guarantees they are exported and have the
      // expected provider types. The runtimeType strings are not stable
      // across Riverpod versions, so we just check non-null identity.
      expect(authProvider, isNotNull);
      expect(hasSessionProvider, isNotNull);
      expect(profileProvider, isNotNull);
      expect(routeGuardProfileProvider, isNotNull);
      expect(settingsProvider, isNotNull);
      expect(latestAnalysisProvider, isNotNull);
      expect(analysisProvider('test-goal'), isNotNull);
    });

    test('routeGuardProfileProvider returns null when profile not loaded', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      // profileProvider's `build` will start loading and ultimately
      // error (no Supabase / no Dio), but during the loading phase
      // the derived provider should yield null per its `orElse`.
      final RouteGuardProfile? snapshot =
          container.read(routeGuardProfileProvider);
      expect(snapshot, isNull);
    });

    test('Profile.fromJson/copyWith round-trip', () {
      final Profile p = Profile.fromJson(<String, dynamic>{
        'id': 'uid-1',
        'email': 'a@b.test',
        'github_url': 'https://github.com/a',
        'linkedin_url': null,
        'goal': null,
        'created_at': '2024-01-02T03:04:05Z',
      });

      expect(p.id, 'uid-1');
      expect(p.email, 'a@b.test');
      expect(p.githubUrl, 'https://github.com/a');
      expect(p.linkedinUrl, isNull);
      expect(p.goal, isNull);

      final Profile patched = p.copyWith(linkedinUrl: 'https://x.test/in');
      expect(patched.linkedinUrl, 'https://x.test/in');
      // copyWith preserves the existing GitHub URL.
      expect(patched.githubUrl, 'https://github.com/a');
    });
  });
}
