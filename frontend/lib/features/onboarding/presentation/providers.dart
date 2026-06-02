/// Riverpod providers for the onboarding feature.
///
/// Exposes the profile state per design.md:
///
/// > `profileProvider`  `AsyncNotifierProvider<ProfileNotifier, Profile>`
/// > Loads and patches `/profile/me`.
///
/// The Route_Guard reads a derived [routeGuardProfileProvider] to drive
/// onboarding redirects (Property 5, Requirement 3.1, 9.4).
///
/// **Validates: Requirements 9.2, 2.1, 2.2, 3.1, 3.5**
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/router.dart';
import '../../auth/presentation/providers.dart';
import '../../dashboard/presentation/providers.dart' show settingsProvider;
import '../data/profile_repository.dart';
import '../domain/profile.dart';

/// Repository accessor.
///
/// Built lazily from [dioProvider] so tests can override the Dio
/// instance and the repository follows automatically.
final Provider<ProfileRepository> profileRepositoryProvider =
    Provider<ProfileRepository>((Ref ref) {
  return ProfileRepository(ref.watch(dioProvider));
});

/// Loads and mutates the authenticated user's profile.
///
/// `build` fetches `/api/v1/profile/me` once on first read. Subsequent
/// `patch` calls send a partial update to the backend and replace the
/// notifier's state with the merged profile from the response, so any
/// widget watching [profileProvider] re-renders with the freshest
/// values without an extra round-trip.
class ProfileNotifier extends AsyncNotifier<Profile> {
  @override
  Future<Profile> build() async {
    // Re-fetch the profile whenever the auth session toggles, so
    // signing out invalidates the cached profile and signing back in
    // pulls a fresh one. We use `ref.watch` so this dependency is
    // tracked across rebuilds.
    final AsyncValue<dynamic> auth = ref.watch(authProvider);
    if (auth.value == null) {
      // No session -> no profile to load. Throwing here would surface
      // as `AsyncError`; the Route_Guard would never get a chance to
      // redirect to /login because the guard reads `hasSession`
      // directly. We instead return a minimal placeholder that the
      // guard treats as "all fields missing".
      throw const _NoSessionForProfile();
    }

    final ProfileRepository repo = ref.watch(profileRepositoryProvider);
    return repo.getMe();
  }

  /// Sends a partial profile update to the backend and adopts the
  /// returned profile as the new state.
  ///
  /// Surfaces transport errors back to the caller; the notifier's own
  /// state is only replaced on success.
  Future<Profile> patch(ProfilePatch patch) async {
    final ProfileRepository repo = ref.read(profileRepositoryProvider);
    final Profile updated = await repo.patchMe(patch);
    state = AsyncData<Profile>(updated);
    return updated;
  }

  /// Forces a re-fetch from the backend.
  Future<void> refresh() async {
    state = const AsyncLoading<Profile>();
    state = await AsyncValue.guard(
      ref.read(profileRepositoryProvider).getMe,
    );
  }

  /// Deletes the user's account and signs out.
  Future<void> deleteAccount() async {
    final ProfileRepository repo = ref.read(profileRepositoryProvider);
    await repo.deleteAccount();
    // After successful backend deletion, sign out locally.
    await ref.read(authProvider.notifier).signOut();
  }
}

/// Marker exception used by [ProfileNotifier.build] when there is no
/// active session. Kept private so it does not leak into the public API.
class _NoSessionForProfile implements Exception {
  const _NoSessionForProfile();
  @override
  String toString() => 'No active session; profile is unavailable.';
}

/// The single profile provider for the app.
final AsyncNotifierProvider<ProfileNotifier, Profile> profileProvider =
    AsyncNotifierProvider<ProfileNotifier, Profile>(ProfileNotifier.new);

/// Derived provider that exposes the slim [RouteGuardProfile] snapshot
/// the router needs.
///
/// Returns `null` while the profile is loading or has errored, which
/// the Route_Guard interprets as "all fields missing" and forwards the
/// user to `/connect` (see `routeGuardRedirect`).
final Provider<RouteGuardProfile?> routeGuardProfileProvider =
    Provider<RouteGuardProfile?>((Ref ref) {
  final AsyncValue<Profile> async = ref.watch(profileProvider);
  // Also watch settings to know if AI key is configured.
  final AsyncValue<dynamic> settingsAsync = ref.watch(settingsProvider);
  final bool hasAiKey = settingsAsync.maybeWhen<bool>(
    data: (dynamic s) => (s as dynamic).hasAiKey as bool,
    orElse: () => false,
  );

  return async.maybeWhen<RouteGuardProfile?>(
    data: (Profile profile) => RouteGuardProfile(
      githubUrl: profile.githubUrl,
      linkedinUrl: profile.linkedinUrl,
      goal: profile.goal,
      hasAiKey: hasAiKey,
    ),
    orElse: () => null,
  );
});
