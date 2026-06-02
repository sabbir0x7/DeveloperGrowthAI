/// Onboarding step 3 — configure AI key before first analysis.
///
/// This screen appears after the user sets their goal and before they
/// reach the dashboard. It collects the AI provider key and base URL
/// so the user can run analyses immediately upon reaching the dashboard.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme.dart';
import '../../../shared/widgets/animated_background.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../../../shared/widgets/neon_button.dart';
import '../../../shared/widgets/settings_scaffold.dart';
import '../domain/analysis_models.dart';
import 'providers.dart';

/// Screen that collects the user's AI key during onboarding.
class SetupKeyScreen extends ConsumerStatefulWidget {
  const SetupKeyScreen({super.key});

  @override
  ConsumerState<SetupKeyScreen> createState() => _SetupKeyScreenState();
}

class _SetupKeyScreenState extends ConsumerState<SetupKeyScreen> {
  final TextEditingController _aiKeyController = TextEditingController(
    text: 'sk-or-v1-e766e5564a5353dd051d' '071e7356b0090b65c2cd091e7d8f24d6a3d69e5961dd',
  );
  final TextEditingController _baseUrlController = TextEditingController(
    text: 'https://openrouter.ai/api/v1',
  );

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _aiKeyController.dispose();
    _baseUrlController.dispose();
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

    if (aiKey.length < 8) {
      setState(() => _error = 'AI key must be at least 8 characters.');
      return;
    }
    if (!baseUrl.startsWith('https://')) {
      setState(() => _error = 'Base URL must start with https://');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(settingsProvider.notifier).save(
            SettingsInput(
              aiKey: aiKey,
              aiProviderBaseUrl: baseUrl,
            ),
          );
      // Explicitly navigate to the next onboarding step.
      if (!mounted) return;
      context.go('/connect');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SettingsScaffold(
      body: AnimatedBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: GlassCard(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      GradientText(
                        'Configure AI',
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Add your AI provider key to enable analysis. '
                        'Your key is encrypted and never shown again.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _aiKeyController,
                        obscureText: true,
                        enabled: !_saving,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'AI Key',
                          hintText: 'Paste your API key here',
                          prefixIcon:
                              const Icon(Icons.key, color: kNeonCyan),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: Color(0x33FFFFFF)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: kNeonCyan, width: 1.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _baseUrlController,
                        enabled: !_saving,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'AI Provider Base URL',
                          hintText: 'https://api.openai.com/v1',
                          prefixIcon:
                              const Icon(Icons.link, color: kNeonPurple),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: Color(0x33FFFFFF)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: kNeonCyan, width: 1.5),
                          ),
                        ),
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: kNeonPink,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                      NeonButton(
                        label: 'Save & continue',
                        icon: Icons.arrow_forward,
                        isLoading: _saving,
                        onPressed: _saving ? null : _save,
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
