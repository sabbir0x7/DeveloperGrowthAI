/// Skill gap view showing identified skill gaps from analysis.
///
/// Renders the `skill_gaps` list from an [AnalysisResult] as a set of
/// expandable glassmorphism cards with severity indicators, current vs
/// target level visualization, importance, and learning resources.
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

    // Count gaps by level for summary
    final int highCount =
        skillGaps.where((SkillGap g) => g.gapLevel == GapLevel.high).length;
    final int mediumCount =
        skillGaps.where((SkillGap g) => g.gapLevel == GapLevel.medium).length;
    final int lowCount =
        skillGaps.where((SkillGap g) => g.gapLevel == GapLevel.low).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GradientText(
          'Skill Gaps',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),

        // Summary chips
        if (skillGaps.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (highCount > 0)
                _SummaryChip(
                  label: '$highCount Critical',
                  color: kNeonPink,
                ),
              if (mediumCount > 0)
                _SummaryChip(
                  label: '$mediumCount Moderate',
                  color: kNeonPurple,
                ),
              if (lowCount > 0)
                _SummaryChip(
                  label: '$lowCount Minor',
                  color: kNeonCyan,
                ),
            ],
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

/// Small summary chip showing count per level.
class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// An expandable skill gap card with rich detail.
class _SkillGapCard extends StatefulWidget {
  const _SkillGapCard({required this.gap});

  final SkillGap gap;

  @override
  State<_SkillGapCard> createState() => _SkillGapCardState();
}

class _SkillGapCardState extends State<_SkillGapCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

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

  double _levelProgress(GapLevel level) {
    switch (level) {
      case GapLevel.high:
        return 0.85;
      case GapLevel.medium:
        return 0.55;
      case GapLevel.low:
        return 0.25;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = _levelColor(widget.gap.gapLevel);
    final bool hasDetails = widget.gap.currentLevel.isNotEmpty ||
        widget.gap.targetLevel.isNotEmpty ||
        widget.gap.importance.isNotEmpty ||
        widget.gap.resources.isNotEmpty;

    return GlassCard(
      padding: EdgeInsets.zero,
      borderColor: _expanded ? color.withValues(alpha: 0.4) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: hasDetails ? () => setState(() => _expanded = !_expanded) : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Header: Name + Level badge + expand icon
              Row(
                children: <Widget>[
                  // Gap severity dot
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.gap.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
                      _levelLabel(widget.gap.gapLevel),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (hasDetails) ...<Widget>[
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.5),
                        size: 20,
                      ),
                    ),
                  ],
                ],
              ),

              // Gap severity bar
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _levelProgress(widget.gap.gapLevel),
                  backgroundColor: color.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    color.withValues(alpha: 0.7),
                  ),
                  minHeight: 4,
                ),
              ),

              // Rationale (always shown)
              const SizedBox(height: 12),
              Text(
                widget.gap.rationale,
                style: theme.textTheme.bodyMedium,
              ),

              // Expanded details
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: _buildExpandedContent(theme, color),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 250),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedContent(ThemeData theme, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Current vs Target Level
          if (widget.gap.currentLevel.isNotEmpty ||
              widget.gap.targetLevel.isNotEmpty) ...<Widget>[
            Divider(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
            const SizedBox(height: 8),

            // Current Level
            if (widget.gap.currentLevel.isNotEmpty) ...<Widget>[
              _DetailSection(
                icon: Icons.person_outline,
                iconColor: Colors.orangeAccent,
                title: 'Current Level',
                content: widget.gap.currentLevel,
              ),
              const SizedBox(height: 12),
            ],

            // Target Level
            if (widget.gap.targetLevel.isNotEmpty) ...<Widget>[
              _DetailSection(
                icon: Icons.flag_outlined,
                iconColor: Colors.greenAccent,
                title: 'Target Level',
                content: widget.gap.targetLevel,
              ),
              const SizedBox(height: 12),
            ],
          ],

          // Importance
          if (widget.gap.importance.isNotEmpty) ...<Widget>[
            Divider(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
            const SizedBox(height: 8),
            _DetailSection(
              icon: Icons.priority_high,
              iconColor: color,
              title: 'Why This Matters',
              content: widget.gap.importance,
            ),
            const SizedBox(height: 12),
          ],

          // Resources
          if (widget.gap.resources.isNotEmpty) ...<Widget>[
            Divider(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Icon(
                  Icons.menu_book_outlined,
                  size: 16,
                  color: kNeonCyan.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 8),
                Text(
                  'Learning Resources',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: kNeonCyan,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...widget.gap.resources.map((String resource) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Icon(
                          Icons.arrow_right,
                          size: 16,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          resource,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

/// A labeled detail section with an icon.
class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.content,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 16, color: iconColor.withValues(alpha: 0.8)),
            const SizedBox(width: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: iconColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Text(
            content,
            style: theme.textTheme.bodySmall?.copyWith(
              color:
                  theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }
}
