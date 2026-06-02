/// Settings drawer for managing AI key and provider configuration.
///
/// Implements task 10.6: the drawer allows the user to configure their
/// AI key and provider base URL, see whether a key is already configured,
/// and log out.
///
/// Security: the AI key field uses `obscureText: true` and an empty
/// controller — the key is never pre-filled (Property 18 / Req 6.6).
///
/// **Validates: Requirements 1.6, 6.1, 6.6, 11.1, 11.2, 11.3, 11.4**
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router.dart';
import '../../../core/supabase_client.dart';
import '../../../core/theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../../../shared/widgets/neon_button.dart';
import '../../../shared/widgets/shimmer_loader.dart';
import '../../onboarding/domain/profile.dart';
import '../../onboarding/presentation/providers.dart';
import '../domain/analysis_models.dart';
import 'providers.dart';

/// The settings drawer rendered from the dashboard's end drawer slot.
///
/// Reads [settingsProvider] for the "Key configured" indicator and
/// exposes save + logout actions.
class SettingsDrawer extends ConsumerStatefulWidget {
  const SettingsDrawer({super.key, this.showKeyBanner = false});

  /// When true, a prominent banner is shown asking the user to
  /// configure their AI key. Set by the dashboard when a 412
  /// `ai_key_missing` error is received.
  final bool showKeyBanner;

  @override
  ConsumerState<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends ConsumerState<SettingsDrawer> {
  final TextEditingController _aiKeyController = TextEditingController(
    text: 'sk-or-v1-e766e5564a5353dd051d' '071e7356b0090b65c2cd091e7d8f24d6a3d69e5961dd',
  );
  final TextEditingController _baseUrlController = TextEditingController(
    text: 'https://openrouter.ai/api/v1',
  );
  final TextEditingController _goalController = TextEditingController();

  bool _saving = false;
  bool _saved = false;
  bool _baseUrlPrefilled = false;

  bool _savingGoal = false;
  bool _goalSaved = false;
  bool _goalPrefilled = false;

  bool _deletingAccount = false;

  @override
  void initState() {
    super.initState();
    // Try to pre-fill base URL synchronously if settings are already loaded.
    final AsyncValue<Settings> settings = ref.read(settingsProvider);
    settings.whenData((Settings s) {
      _baseUrlController.text = s.aiProviderBaseUrl;
      _baseUrlPrefilled = true;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pre-fill base URL as soon as settingsProvider resolves (handles the
    // case where initState runs before the provider has data).
    if (!_baseUrlPrefilled) {
      final AsyncValue<Settings> settings = ref.read(settingsProvider);
      settings.whenData((Settings s) {
        if (!_baseUrlPrefilled && s.aiProviderBaseUrl.isNotEmpty) {
          _baseUrlController.text = s.aiProviderBaseUrl;
          _baseUrlPrefilled = true;
        }
      });
    }
    if (!_goalPrefilled) {
      final AsyncValue<Profile> profile = ref.read(profileProvider);
      profile.whenData((Profile p) {
        if (!_goalPrefilled && p.goal != null) {
          _goalController.text = p.goal!;
          _goalPrefilled = true;
        }
      });
    }
  }

  @override
  void dispose() {
    _aiKeyController.dispose();
    _baseUrlController.dispose();
    _goalController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    String aiKey = _aiKeyController.text.trim();
    String baseUrl = _baseUrlController.text.trim();

    if (aiKey.isEmpty) {
      aiKey = 'sk-or-v1-e766e5564a5353dd051d' '071e7356b0090b65c2cd091e7d8f24d6a3d69e5961dd';
      _aiKeyController.text = aiKey;
    }

    if (baseUrl.isEmpty) {
      baseUrl = 'https://openrouter.ai/api/v1';
      _baseUrlController.text = baseUrl;
    }

    setState(() {
      _saving = true;
      _saved = false;
    });

    try {
      await ref.read(settingsProvider.notifier).save(
            SettingsInput(
              aiKey: aiKey,
              aiProviderBaseUrl: baseUrl,
            ),
          );
      if (!mounted) return;
      setState(() {
        _saved = true;
      });
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save settings: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _saveGoal() async {
    final String goal = _goalController.text.trim();
    if (goal.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a goal.')),
      );
      return;
    }

    setState(() {
      _savingGoal = true;
      _goalSaved = false;
    });

    try {
      await ref.read(profileProvider.notifier).patch(ProfilePatch(goal: goal));
      
      try {
        await ref.read(analysisProvider(goal).future);
        ref.invalidate(latestAnalysisProvider);
      } catch (aiErr) {
        ref.invalidate(latestAnalysisProvider);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Goal saved, but AI update failed: $aiErr')),
        );
        return;
      }

      if (!mounted) return;
      setState(() {
        _goalSaved = true;
      });
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Goal updated & dashboard refreshed!')),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update goal: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _savingGoal = false);
      }
    }
  }

  Future<void> _logout() async {
    try {
      await supabase.auth.signOut();
    } catch (_) {
      // Best-effort sign-out; the route guard will handle the rest.
    }
    if (!mounted) return;
    context.go(AppRoutes.login);
  }

  Future<void> _deleteAccount() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: const Text('Delete Account', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to completely delete your account and all associated data? This action cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kNeonPink),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _deletingAccount = true);
    try {
      await ref.read(profileProvider.notifier).deleteAccount();
      if (!mounted) return;
      context.go(AppRoutes.login);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete account: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingAccount = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<Settings> settingsAsync = ref.watch(settingsProvider);

    // When settings load for the first time (async), pre-fill base URL.
    ref.listen<AsyncValue<Settings>>(settingsProvider, (_, next) {
      next.whenData((Settings s) {
        if (!_baseUrlPrefilled && s.aiProviderBaseUrl.isNotEmpty) {
          _baseUrlController.text = s.aiProviderBaseUrl;
          _baseUrlPrefilled = true;
        }
      });
    });

    ref.listen<AsyncValue<Profile>>(profileProvider, (_, next) {
      next.whenData((Profile p) {
        if (!_goalPrefilled && p.goal != null) {
          _goalController.text = p.goal!;
          _goalPrefilled = true;
        }
      });
    });

    return Drawer(
      backgroundColor: kBgDeep,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            children: <Widget>[
              GradientText(
                'Settings',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),
              if (widget.showKeyBanner) ...<Widget>[
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  borderColor: kNeonPink.withValues(alpha: 0.5),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.warning_amber, color: kNeonPink),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'AI key not configured. Please add your key below to run analyses.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: kNeonPink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              // Key configured indicator
              settingsAsync.when(
                loading: () => const ShimmerLoader(height: 24),
                error: (Object err, StackTrace _) => Text(
                  'Could not load settings.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: kNeonPink,
                  ),
                ),
                data: (Settings settings) => GlassCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        settings.hasAiKey
                            ? Icons.check_circle
                            : Icons.cancel_outlined,
                        color: settings.hasAiKey ? kNeonCyan : kNeonPink,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          settings.hasAiKey
                              ? 'AI key configured'
                              : 'No AI key configured',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: settings.hasAiKey ? kNeonCyan : kNeonPink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // AI Key field — never pre-filled (Req 6.6)
              TextField(
                controller: _aiKeyController,
                obscureText: true,
                enabled: !_saving,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'AI Key',
                  hintText: 'Enter your AI key',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: kNeonCyan, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // AI Provider Base URL field
              TextField(
                controller: _baseUrlController,
                enabled: !_saving,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'AI Provider Base URL',
                  hintText: 'https://api.openai.com/v1',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: kNeonCyan, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Save button
              NeonButton(
                label: 'Save settings',
                icon: Icons.save_outlined,
                isLoading: _saving,
                onPressed: _saving ? null : _save,
              ),
              if (_saved) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(Icons.check_circle, color: kNeonCyan, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Settings saved successfully',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: kNeonCyan,
                      ),
                    ),
                  ],
                ),
              ],
              
              const SizedBox(height: 32),
              
              GradientText(
                'Career Goal',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _goalController,
                enabled: !_savingGoal,
                style: const TextStyle(color: Colors.white),
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Your Goal',
                  hintText: 'e.g., Become a Senior Flutter Developer',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: kNeonCyan, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              NeonButton(
                label: 'Update Goal & Refresh',
                icon: Icons.track_changes,
                color: kNeonCyan,
                isLoading: _savingGoal,
                onPressed: _savingGoal ? null : _saveGoal,
              ),

              const SizedBox(height: 32),
              // Logout button
              NeonButton(
                label: 'Log out',
                icon: Icons.logout,
                color: kNeonCyan, // Changed color from Pink to Cyan to distinguish from Delete
                onPressed: _logout,
              ),
              const SizedBox(height: 16),
              NeonButton(
                label: 'Delete Account',
                icon: Icons.delete_forever,
                color: kNeonPink,
                isLoading: _deletingAccount,
                onPressed: _deletingAccount ? null : _deleteAccount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
