/// Onboarding step 2 — Set Goal screen.
///
/// Renders the glassmorphism-styled "Set your career goal" screen and
/// persists the user's goal via `PATCH /profile/me`. Once persisted,
/// the Route_Guard in `core/router.dart` forwards the user to
/// `/dashboard` (Requirement 3.5).
///
/// The screen owns its own [TextEditingController], runs the pure
/// [validateGoal] helper inline on every change, and gates the submit
/// CTA on a `null` validation result. Per Property 6 in `design.md`,
/// no HTTP request is issued when validation fails.
///
/// **Validates: Requirements 3.3, 3.4, 3.5**
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router.dart';
import '../../../core/theme.dart';
import '../../../shared/widgets/animated_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../../../shared/widgets/neon_button.dart';
import '../../../shared/widgets/settings_scaffold.dart';
import '../../dashboard/data/analysis_repository.dart';
import '../../dashboard/presentation/providers.dart';
import '../domain/profile.dart';
import 'providers.dart';

/// Maximum number of characters allowed in a career goal.
///
/// Mirrors the cap enforced by `backend/app/schemas/profile.py`
/// (Requirement 3.3). Exposed as a top-level const so the property
/// test in task 10.4 can reference it directly.
const int kGoalMaxLength = 500;

/// Validates a candidate goal string. Returns `null` when the string is
/// acceptable, or a human-readable error message otherwise.
///
/// Validation rules, mirroring the inline UI checks on [SetGoalScreen]:
///   * Empty input is rejected.
///   * Whitespace-only input is rejected (the trimmed string is empty).
///   * Strings longer than [kGoalMaxLength] are rejected.
///
/// The function is pure and dependency-free so the property test in
/// task 10.4 (`frontend/test/property/set_goal_validation_test.dart`)
/// can exercise it without booting the widget tree.
///
/// **Property 6 — Goal validation rejects empty and oversize input.**
/// **Validates: Requirement 3.4**
String? validateGoal(String input) {
  if (input.isEmpty) {
    return 'Please enter a career goal.';
  }
  if (input.trim().isEmpty) {
    return 'Goal cannot be only whitespace.';
  }
  if (input.length > kGoalMaxLength) {
    return 'Goal must be $kGoalMaxLength characters or fewer.';
  }
  return null;
}

/// The Set Goal onboarding screen.
///
/// Reads/writes [profileProvider] for the goal patch. The screen does
/// not consume the loaded profile directly — the Route_Guard handles
/// forwarding to `/dashboard` once the goal lands in state.
class SetGoalScreen extends ConsumerStatefulWidget {
  const SetGoalScreen({super.key});

  @override
  ConsumerState<SetGoalScreen> createState() => _SetGoalScreenState();
}

class _SetGoalScreenState extends ConsumerState<SetGoalScreen> {
  late final TextEditingController _controller;

  /// Inline validation error for the current input. `null` when the
  /// input is valid. Only displayed after the user has interacted with
  /// the field once (`_showError` flips true on first submit).
  String? _error;

  /// Whether the user has attempted submit at least once. We hide the
  /// inline error before the first submit so the empty initial field
  /// does not display as "invalid" on mount.
  bool _showError = false;

  /// True while a `PATCH /profile/me` is in flight.
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // Re-run validation on every keystroke so the counter color and
    // (after first submit) the inline error update live.
    final String? next = validateGoal(_controller.text);
    if (next != _error) {
      setState(() => _error = next);
    } else {
      // Always trigger a rebuild for the counter color even when the
      // validity has not flipped (e.g. growing past 500 already-invalid).
      setState(() {});
    }
  }

  Future<void> _submit() async {
    final String raw = _controller.text;
    final String? validation = validateGoal(raw);

    // Property 6: surface the inline error and bail out before any
    // HTTP request whenever validation fails.
    if (validation != null) {
      setState(() {
        _error = validation;
        _showError = true;
      });
      return;
    }

    setState(() {
      _error = null;
      _showError = true;
      _submitting = true;
    });

    final String trimmed = raw.trim();
    try {
      // Step 1: Save the goal
      await ref
          .read(profileProvider.notifier)
          .patch(ProfilePatch(goal: trimmed));

      // Step 2: Run analysis immediately
      await ref.read(analysisProvider(trimmed).future);

      // Step 3: Refresh latest analysis and navigate to dashboard
      ref.invalidate(latestAnalysisProvider);
      if (!mounted) return;
      context.go(AppRoutes.dashboard);
    } on MissingAIKeyException {
      if (!mounted) return;
      setState(() {
        _error = 'AI key not configured. Please go back and set it up.';
      });
    } on AnalysisRateLimitedException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Rate limited. Retry in ${e.retryAfterSeconds ?? 60}s.';
      });
    } on UpstreamAIException {
      if (!mounted) return;
      setState(() {
        _error = 'AI service temporarily unavailable. Try again.';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong. Please try again.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int length = _controller.text.length;
    final bool overLimit = length > kGoalMaxLength;
    final Color counterColor = overLimit ? kNeonPink : Colors.white70;

    return SettingsScaffold(
      body: AnimatedBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 32,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: GlassCard(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      GradientText(
                        'Set your goal',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Tell us where you want to grow. We use this to '
                        'tailor your skill gap analysis and suggested '
                        'roadmap.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),
                      _GoalField(
                        controller: _controller,
                        errorText: _showError ? _error : null,
                        enabled: !_submitting,
                        onSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          '$length / $kGoalMaxLength',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: counterColor),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Center(
                        child: NeonButton(
                          label: 'Run Analysis',
                          icon: Icons.analytics_outlined,
                          isLoading: _submitting,
                          onPressed: _submitting ? null : _submit,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The multi-line goal text field, separated out so the parent widget
/// stays readable.
class _GoalField extends StatelessWidget {
  const _GoalField({
    required this.controller,
    required this.errorText,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final String? errorText;
  final bool enabled;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      maxLines: 4,
      minLines: 3,
      // Intentionally omit `maxLength` so the user can type past the
      // 500-char limit and see the inline validation fire (Property 6
      // requires the screen to *reject* oversize input rather than
      // silently truncate it).
      textInputAction: TextInputAction.done,
      keyboardType: TextInputType.multiline,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: 'Career goal',
        hintText: 'e.g. Become a Senior Backend Engineer',
        helperText: 'Up to $kGoalMaxLength characters.',
        errorText: errorText,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x33FFFFFF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x33FFFFFF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kNeonCyan, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kNeonPink, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kNeonPink, width: 1.5),
        ),
      ),
    );
  }
}
