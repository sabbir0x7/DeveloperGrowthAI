/// Analysis view showing GitHub and LinkedIn analysis results.
///
/// Renders the free-form `github_analysis` and `linkedin_analysis` maps
/// from an [AnalysisResult] inside glassmorphism cards.
///
/// **Validates: Requirements 5.4, 10.2, 10.5**
library;

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../domain/analysis_models.dart';

/// Displays the GitHub and LinkedIn analysis sections of an
/// [AnalysisResult].
class AnalysisView extends StatelessWidget {
  const AnalysisView({super.key, required this.result});

  /// The analysis result to render.
  final AnalysisResult result;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GradientText(
          'Profile Analysis',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        _AnalysisCard(
          title: 'GitHub Analysis',
          icon: Icons.code,
          data: result.githubAnalysis,
        ),
        const SizedBox(height: 16),
        _AnalysisCard(
          title: 'LinkedIn Analysis',
          icon: Icons.business,
          data: result.linkedinAnalysis,
        ),
      ],
    );
  }
}

class _AnalysisCard extends StatelessWidget {
  const _AnalysisCard({
    required this.title,
    required this.icon,
    required this.data,
  });

  final String title;
  final IconData icon;
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: kNeonCyan, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (data.isEmpty)
            Text(
              'No data available.',
              style: theme.textTheme.bodyMedium,
            )
          else
            ...data.entries.map((MapEntry<String, dynamic> entry) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _formatKey(entry.key),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: kNeonPurple,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatValue(entry.value),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  String _formatKey(String key) {
    return key
        .replaceAll('_', ' ')
        .split(' ')
        .map((String word) =>
            word.isEmpty ? '' : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }

  String _formatValue(dynamic value) {
    if (value is List) {
      return value.map((dynamic e) => e.toString()).join(', ');
    }
    if (value is Map) {
      return value.entries
          .map((MapEntry<dynamic, dynamic> e) => '${e.key}: ${e.value}')
          .join('\n');
    }
    return value.toString();
  }
}
