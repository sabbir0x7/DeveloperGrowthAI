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

import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/providers.dart';
import '../../../core/router.dart';
import '../../auth/presentation/providers.dart';
import '../../dashboard/domain/analysis_models.dart' show AnalysisRequest;
import '../../dashboard/presentation/providers.dart' show settingsProvider, analysisRepositoryProvider, latestAnalysisProvider;
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
    // We catch exceptions here because the user record is gone, so the server
    // will likely reject the sign-out request with 401/404.
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      // Best-effort sign-out; ignore errors since the account is deleted.
    }
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

/// Notifier to manage the profile analysis execution state globally.
///
/// Supports cancellation: the user can abort a running analysis and
/// immediately start a new one with a corrected goal. The in-flight
/// HTTP call is cancelled via Dio's [CancelToken].
class ProfileAnalysisStateNotifier extends Notifier<bool> {
  /// Token for the currently in-flight analysis HTTP call, if any.
  CancelToken? _cancelToken;

  @override
  bool build() => false;

  /// Cancels the in-flight analysis (if any) and resets the spinner.
  ///
  /// Safe to call even when no analysis is running.
  void cancel() {
    _cancelToken?.cancel('User cancelled the analysis.');
    _cancelToken = null;
    state = false;
  }

  Future<void> runAnalysis({
    required String goal,
    required void Function() onSuccess,
    required void Function(Object error) onError,
  }) async {
    // Cancel any previous in-flight analysis so the user can immediately
    // re-run with a corrected goal without waiting for the old one.
    _cancelToken?.cancel('Superseded by new analysis.');

    final CancelToken token = CancelToken();
    _cancelToken = token;

    // Set loading state globally.
    state = true;

    try {
      // Step 1: Save the goal and capture the updated profile.
      final Profile updated = await ref.read(profileProvider.notifier).patch(
        ProfilePatch(goal: goal),
      );

      // Step 2: Run analysis directly via the repository.
      final String? githubUrl = updated.githubUrl;
      final String? linkedinUrl = updated.linkedinUrl;
      if (githubUrl == null || linkedinUrl == null) {
        throw StateError(
          'Cannot run analysis: profile is missing github_url or linkedin_url.',
        );
      }

      await ref.read(analysisRepositoryProvider).run(
        AnalysisRequest(
          githubUrl: githubUrl,
          linkedinUrl: linkedinUrl,
          goal: goal,
        ),
        cancelToken: token,
      );

      // Bail out if this operation was cancelled while awaiting.
      if (token.isCancelled) return;

      // Step 3: Refresh latest analysis and wait for the data.
      ref.invalidate(latestAnalysisProvider);
      await ref.read(latestAnalysisProvider.future);

      if (token.isCancelled) return;

      // Step 4: Success block.
      onSuccess();
    } on DioException catch (e) {
      // Silently swallow cancellation — the user intentionally aborted.
      if (e.type == DioExceptionType.cancel) return;
      onError(e);
    } catch (e) {
      onError(e);
    } finally {
      // Only reset state if this is still the current operation.
      // If a new runAnalysis was started (superseding this one), its
      // token will differ and we must not clobber its loading state.
      if (_cancelToken == token) {
        _cancelToken = null;
        state = false;
      }
    }
  }
}

/// Exposes the global loading state of the Profile Analysis.
final profileAnalysisStateProvider = NotifierProvider<ProfileAnalysisStateNotifier, bool>(ProfileAnalysisStateNotifier.new);
