/// Suggestions view showing AI-generated roadmap suggestions.
///
/// Renders the `suggestions` list from an [AnalysisResult] as a set of
/// glassmorphism cards with priority indicators.
///
/// **Validates: Requirements 5.4, 10.2**
library;

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../domain/analysis_models.dart';

/// Displays the suggestions section of an [AnalysisResult].
class SuggestionsView extends StatelessWidget {
  const SuggestionsView({super.key, required this.suggestions});

  /// The suggestions to render.
  final List<Suggestion> suggestions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GradientText(
          'Suggestions',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        if (suggestions.isEmpty)
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Text(
              'No suggestions available yet.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          )
        else
          ...suggestions.map((Suggestion suggestion) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _SuggestionCard(suggestion: suggestion),
              )),
      ],
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion});

  final Suggestion suggestion;

  Color _priorityColor(SuggestionPriority priority) {
    switch (priority) {
      case SuggestionPriority.high:
        return kNeonPink;
      case SuggestionPriority.medium:
        return kNeonPurple;
      case SuggestionPriority.low:
        return kNeonCyan;
    }
  }

  String _priorityLabel(SuggestionPriority priority) {
    switch (priority) {
      case SuggestionPriority.high:
        return 'High';
      case SuggestionPriority.medium:
        return 'Medium';
      case SuggestionPriority.low:
        return 'Low';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = _priorityColor(suggestion.priority);

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  suggestion.title,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: color.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  _priorityLabel(suggestion.priority),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            suggestion.description,
            style: theme.textTheme.bodyMedium,
          ),
          if (suggestion.timeline.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Icon(Icons.schedule, size: 16, color: kNeonCyan),
                const SizedBox(width: 6),
                Text(
                  'Timeline: ${suggestion.timeline}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: kNeonCyan,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
          if (suggestion.steps.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            ...suggestion.steps.asMap().entries.map(
              (MapEntry<int, String> entry) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kNeonPurple.withValues(alpha: 0.2),
                      ),
                      child: Text(
                        '${entry.key + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: kNeonPurple,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.value,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
