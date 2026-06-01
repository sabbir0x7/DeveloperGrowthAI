/// Skill gap view showing identified skill gaps from analysis.
///
/// Renders the `skill_gaps` list from an [AnalysisResult] as a set of
/// glassmorphism cards with severity indicators.
///
/// **Validates: Requirements 5.4, 10.2**
library;

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/gradient_text.dart';
import '../domain/analysis_models.dart';

/// Displays the skill gaps section of an [AnalysisResult].
class SkillGapView extends StatelessWidget {
  const SkillGapView({super.key, required this.skillGaps});

  /// The skill gaps to render.
  final List<SkillGap> skillGaps;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GradientText(
          'Skill Gaps',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        if (skillGaps.isEmpty)
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Text(
              'No skill gaps identified yet.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          )
        else
          ...skillGaps.map((SkillGap gap) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _SkillGapCard(gap: gap),
              )),
      ],
    );
  }
}

class _SkillGapCard extends StatelessWidget {
  const _SkillGapCard({required this.gap});

  final SkillGap gap;

  Color _levelColor(GapLevel level) {
    switch (level) {
      case GapLevel.high:
        return kNeonPink;
      case GapLevel.medium:
        return kNeonPurple;
      case GapLevel.low:
        return kNeonCyan;
    }
  }

  String _levelLabel(GapLevel level) {
    switch (level) {
      case GapLevel.high:
        return 'High';
      case GapLevel.medium:
        return 'Medium';
      case GapLevel.low:
        return 'Low';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = _levelColor(gap.gapLevel);

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  gap.name,
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
                  _levelLabel(gap.gapLevel),
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
            gap.rationale,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
