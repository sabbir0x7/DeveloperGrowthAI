/// Riverpod providers for the dashboard feature.
///
/// Mirrors the provider table in design.md:
///
/// > `settingsProvider`        `AsyncNotifierProvider<SettingsNotifier,
/// >                            Settings>` Loads `/profile/settings`;
/// >                            `has_ai_key` boolean only.
/// > `analysisProvider`        `FutureProvider.family<AnalysisResult,
/// >                            String /*goal*/>` Calls `/analysis/run`
/// >                            and caches per-goal.
/// > `latestAnalysisProvider`  `FutureProvider<AnalysisResult?>`
/// >                            Hits `/analysis/latest` for empty-state
/// >                            vs filled-state Dashboard.
///
/// The Settings drawer reads [settingsProvider] for the "Key configured"
/// indicator (Property 28, Requirement 11.4), the dashboard reads
/// [latestAnalysisProvider] for empty-state vs filled-state rendering
/// (Requirement 5.4, 5.5), and the run button reads
/// [analysisProvider] keyed by the user's current goal so retrying the
/// same goal does not re-bill the AI provider (Requirement 4.5, 4.7).
///
/// **Validates: Requirements 9.2, 5.4, 5.5, 11.4**
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../onboarding/presentation/providers.dart' show profileProvider;
import '../data/analysis_repository.dart';
import '../domain/analysis_models.dart';

/// Repository accessor.
final Provider<AnalysisRepository> analysisRepositoryProvider =
    Provider<AnalysisRepository>((Ref ref) {
  return AnalysisRepository(ref.watch(dioProvider));
});

// ---------------------------------------------------------------------------
// settingsProvider
// ---------------------------------------------------------------------------

/// Loads and mutates the authenticated user's settings (`has_ai_key` +
/// `ai_provider_base_url`). Per Property 18 / Requirement 6.6 the
/// loaded state never carries the AI key.
class SettingsNotifier extends AsyncNotifier<Settings> {
  @override
  Future<Settings> build() async {
    final AnalysisRepository repo = ref.watch(analysisRepositoryProvider);
    return repo.getSettings();
  }

  /// Saves the user's AI key + base URL and adopts the refreshed
  /// settings as state. Surfaces transport errors to the caller.
  Future<Settings> save(SettingsInput input) async {
    final AnalysisRepository repo = ref.read(analysisRepositoryProvider);
    final Settings updated = await repo.putSettings(input);
    state = AsyncData<Settings>(updated);
    return updated;
  }

  /// Forces a re-fetch.
  Future<void> refresh() async {
    state = const AsyncLoading<Settings>();
    state = await AsyncValue.guard(
      ref.read(analysisRepositoryProvider).getSettings,
    );
  }
}

final AsyncNotifierProvider<SettingsNotifier, Settings> settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

// ---------------------------------------------------------------------------
// analysisProvider (family)
// ---------------------------------------------------------------------------

/// Runs a fresh analysis for the supplied goal and caches the result
/// per-goal. Re-watching the family with the same goal short-circuits
/// to the cached value, satisfying the "caches per-goal" clause in
/// design.md.
///
/// The provider reads the URLs from [profileProvider] so the caller
/// only has to pass the goal. If the profile is not yet loaded, the
/// future awaits its resolution before issuing the run.
final analysisProvider = FutureProvider.family<AnalysisResult, String>(
  (Ref ref, String goal) async {
    final AnalysisRepository repo = ref.watch(analysisRepositoryProvider);

    // Wait for the profile to resolve so we can pull the URLs from it.
    // `ref.watch(profileProvider.future)` returns a Future that
    // completes when the AsyncNotifier's `build` finishes.
    final dynamic profile = await ref.watch(profileProvider.future);

    final String? githubUrl = profile.githubUrl as String?;
    final String? linkedinUrl = profile.linkedinUrl as String?;
    if (githubUrl == null || linkedinUrl == null) {
      throw StateError(
        'Cannot run analysis: profile is missing github_url or '
        'linkedin_url. The Route_Guard should have redirected to '
        '/connect before reaching this point.',
      );
    }

    return repo.run(
      AnalysisRequest(
        githubUrl: githubUrl,
        linkedinUrl: linkedinUrl,
        goal: goal,
      ),
    );
  },
);

// ---------------------------------------------------------------------------
// latestAnalysisProvider
// ---------------------------------------------------------------------------

/// Fetches the most recent analysis row for the current user, or `null`
/// when no analyses exist yet (the dashboard renders the empty state in
/// that case).
///
/// Implemented as a [FutureProvider] (per design.md) so the dashboard
/// can `ref.watch(latestAnalysisProvider)` and pattern-match on
/// `AsyncValue<AnalysisResult?>`.
final FutureProvider<AnalysisResult?> latestAnalysisProvider =
    FutureProvider<AnalysisResult?>((Ref ref) async {
  final AnalysisRepository repo = ref.watch(analysisRepositoryProvider);
  return repo.getLatest();
});
