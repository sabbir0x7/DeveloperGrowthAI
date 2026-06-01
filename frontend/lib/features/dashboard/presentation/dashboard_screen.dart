/// Dashboard screen — the signed-in landing page.
///
/// Reads [latestAnalysisProvider] to decide between the empty state
/// (no analyses yet) and the filled state (render analysis cards).
///
/// Error handling for the "Run Analysis" action:
///   * 412 `ai_key_missing` → opens the Settings drawer with a banner.
///   * 429 rate limited → shows a snackbar with Retry-After countdown.
///   * 502 upstream AI error → shows a retry CTA.
///
/// **Validates: Requirements 5.4, 5.5, 4.7, 7.2, 10.2, 10.5, 10.6**
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../shared/widgets/animated_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../../../shared/widgets/neon_button.dart';
import '../../../shared/widgets/shimmer_loader.dart';
import '../../onboarding/presentation/providers.dart';
import '../data/analysis_repository.dart';
import '../domain/analysis_models.dart';
import 'analysis_view.dart';
import 'providers.dart';
import 'settings_drawer.dart';
import 'skill_gap_view.dart';
import 'suggestions_view.dart';

/// The main dashboard screen.
///
/// Uses [AnimatedBackground] with intensity 0.6 for legibility over
/// dense content. The end drawer hosts the [SettingsDrawer].
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _running = false;
  bool _showKeyBanner = false;
  bool _showUpstreamError = false;
  int? _retryAfterSeconds;
  Timer? _retryTimer;

  /// Which tab is currently active: 0 = Result, 1 = Skill Gap, 2 = Suggestions
  int _activeTab = 0;

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _runAnalysis() async {
    if (_running) return;

    // Read the user's goal from the profile.
    final AsyncValue<dynamic> profileAsync = ref.read(profileProvider);
    final String? goal = profileAsync.whenOrNull(
      data: (dynamic profile) => profile.goal as String?,
    );

    if (goal == null || goal.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No goal set. Please set a goal first.'),
        ),
      );
      return;
    }

    setState(() {
      _running = true;
      _showKeyBanner = false;
      _showUpstreamError = false;
      _retryAfterSeconds = null;
    });

    try {
      await ref.read(analysisProvider(goal).future);
      // Refresh the latest analysis so the dashboard re-renders.
      ref.invalidate(latestAnalysisProvider);
    } on MissingAIKeyException {
      if (!mounted) return;
      setState(() => _showKeyBanner = true);
      _scaffoldKey.currentState?.openEndDrawer();
    } on AnalysisRateLimitedException catch (e) {
      if (!mounted) return;
      final int seconds = e.retryAfterSeconds ?? 60;
      setState(() => _retryAfterSeconds = seconds);
      _startRetryCountdown(seconds);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Rate limited. Retry in $seconds seconds.'),
          duration: Duration(seconds: seconds.clamp(3, 10)),
        ),
      );
    } on UpstreamAIException {
      if (!mounted) return;
      setState(() => _showUpstreamError = true);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Analysis failed: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  void _startRetryCountdown(int seconds) {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _retryAfterSeconds = (_retryAfterSeconds ?? 0) - 1;
        if (_retryAfterSeconds != null && _retryAfterSeconds! <= 0) {
          _retryAfterSeconds = null;
          timer.cancel();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<AnalysisResult?> latestAsync =
        ref.watch(latestAnalysisProvider);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      endDrawer: SettingsDrawer(showKeyBanner: _showKeyBanner),
      appBar: AppBar(
        title: GradientText(
          'Dashboard',
          style: theme.textTheme.titleLarge,
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings, color: kNeonCyan),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: AnimatedBackground(
        intensity: 0.6,
        child: SafeArea(
          child: latestAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ShimmerLoader(height: 32),
                  SizedBox(height: 16),
                  ShimmerLoader.lines(lines: 4),
                  SizedBox(height: 24),
                  ShimmerLoader(height: 120),
                ],
              ),
            ),
            error: (Object err, StackTrace _) => _buildErrorState(theme, err),
            data: (AnalysisResult? result) {
              if (result == null) {
                return _buildEmptyState(theme);
              }
              return _buildFilledState(theme, result);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: GlassCard(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.analytics_outlined,
                  size: 64,
                  color: kNeonCyan,
                ),
                const SizedBox(height: 20),
                GradientText(
                  'No analysis yet',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Run your first analysis to get personalized skill gap '
                  'insights and growth suggestions.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                NeonButton(
                  label: 'Run Analysis',
                  icon: Icons.play_arrow,
                  isLoading: _running,
                  onPressed: _running ? null : _runAnalysis,
                ),
                if (_showUpstreamError) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    'The AI service is temporarily unavailable.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: kNeonPink,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  NeonButton(
                    label: 'Retry',
                    icon: Icons.refresh,
                    color: kNeonPurple,
                    onPressed: _running ? null : _runAnalysis,
                  ),
                ],
                if (_retryAfterSeconds != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    'Retry available in $_retryAfterSeconds seconds',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: kNeonPurple,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilledState(ThemeData theme, AnalysisResult result) {
    return Column(
      children: <Widget>[
        // Tab buttons row
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Row(
            children: <Widget>[
              _TabButton(
                label: 'Show Result',
                icon: Icons.analytics_outlined,
                isActive: _activeTab == 0,
                onTap: () => setState(() => _activeTab = 0),
              ),
              const SizedBox(width: 8),
              _TabButton(
                label: 'Skill Gap',
                icon: Icons.trending_up,
                isActive: _activeTab == 1,
                onTap: () => setState(() => _activeTab = 1),
              ),
              const SizedBox(width: 8),
              _TabButton(
                label: 'Suggestions',
                icon: Icons.lightbulb_outline,
                isActive: _activeTab == 2,
                onTap: () => setState(() => _activeTab = 2),
              ),
            ],
          ),
        ),
        if (_showUpstreamError) ...<Widget>[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: GlassCard(
              padding: const EdgeInsets.all(16),
              borderColor: kNeonPink.withValues(alpha: 0.5),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.error_outline, color: kNeonPink),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'AI service unavailable. Please retry.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: kNeonPink,
                      ),
                    ),
                  ),
                  NeonButton(
                    label: 'Retry',
                    icon: Icons.refresh,
                    color: kNeonPurple,
                    minimumSize: const Size(80, 36),
                    onPressed: _running ? null : _runAnalysis,
                  ),
                ],
              ),
            ),
          ),
        ],
        if (_retryAfterSeconds != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            'Retry available in $_retryAfterSeconds seconds',
            style: theme.textTheme.bodySmall?.copyWith(
              color: kNeonPurple,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 16),
        // Tab content
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: _buildTabContent(theme, result),
          ),
        ),
      ],
    );
  }

  Widget _buildTabContent(ThemeData theme, AnalysisResult result) {
    switch (_activeTab) {
      case 0:
        return AnalysisView(result: result);
      case 1:
        return SkillGapView(skillGaps: result.skillGaps);
      case 2:
        return SuggestionsView(suggestions: result.suggestions);
      default:
        return AnalysisView(result: result);
    }
  }

  Widget _buildErrorState(ThemeData theme, Object err) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, color: kNeonPink, size: 48),
              const SizedBox(height: 16),
              Text(
                'Failed to load analysis',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                err.toString(),
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              NeonButton(
                label: 'Retry',
                icon: Icons.refresh,
                onPressed: () => ref.invalidate(latestAnalysisProvider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A neon-styled tab button for the dashboard section switcher.
class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = isActive ? kNeonCyan : Colors.white54;

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isActive
                ? kNeonCyan.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? kNeonCyan.withValues(alpha: 0.5)
                  : Colors.white24,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
