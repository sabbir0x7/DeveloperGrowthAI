/// Domain models for the dashboard feature.
///
/// Mirrors the `AnalysisEnvelope` / `AnalysisResponse` Pydantic schemas
/// from `backend/app/schemas/analysis.py` (see design.md), plus the
/// `Settings` view used by the Settings drawer.
///
/// Only the parts of the envelope the UI actually inspects are
/// modelled with strong types ([SkillGap], [Suggestion]); the
/// `github_analysis` and `linkedin_analysis` blobs are kept as `Map`s
/// because their shape is dictated by the LLM at run time.
library;

import 'package:flutter/foundation.dart';

/// Severity of a skill gap as reported by the AI.
enum GapLevel { low, medium, high }

/// Priority of a roadmap suggestion as reported by the AI.
enum SuggestionPriority { low, medium, high }

GapLevel _parseGapLevel(String raw) {
  switch (raw.toLowerCase()) {
    case 'low':
      return GapLevel.low;
    case 'medium':
      return GapLevel.medium;
    case 'high':
      return GapLevel.high;
    default:
      throw FormatException('Unknown gap_level: "$raw"');
  }
}

SuggestionPriority _parsePriority(String raw) {
  switch (raw.toLowerCase()) {
    case 'low':
      return SuggestionPriority.low;
    case 'medium':
      return SuggestionPriority.medium;
    case 'high':
      return SuggestionPriority.high;
    default:
      throw FormatException('Unknown priority: "$raw"');
  }
}

/// One row in `analysis.skill_gaps`.
@immutable
class SkillGap {
  const SkillGap({
    required this.name,
    required this.gapLevel,
    required this.rationale,
  });

  factory SkillGap.fromJson(Map<String, dynamic> json) {
    return SkillGap(
      name: json['name'] as String,
      gapLevel: _parseGapLevel(json['gap_level'] as String),
      rationale: json['rationale'] as String,
    );
  }

  final String name;
  final GapLevel gapLevel;
  final String rationale;
}

/// One row in `analysis.suggestions`.
@immutable
class Suggestion {
  const Suggestion({
    required this.title,
    required this.description,
    required this.priority,
    this.timeline = '',
    this.steps = const <String>[],
  });

  factory Suggestion.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawSteps =
        (json['steps'] as List<dynamic>? ?? const <dynamic>[]);
    return Suggestion(
      title: json['title'] as String,
      description: json['description'] as String,
      priority: _parsePriority(json['priority'] as String),
      timeline: json['timeline'] as String? ?? '',
      steps: rawSteps.map((dynamic e) => e.toString()).toList(growable: false),
    );
  }

  final String title;
  final String description;
  final SuggestionPriority priority;
  final String timeline;
  final List<String> steps;
}

/// Strongly-typed view of the analysis envelope returned by
/// `POST /analysis/run` and `GET /analysis/latest`.
@immutable
class AnalysisResult {
  const AnalysisResult({
    this.id,
    this.createdAt,
    required this.githubAnalysis,
    required this.linkedinAnalysis,
    required this.skillGaps,
    required this.suggestions,
  });

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> rawSkillGaps =
        (json['skill_gaps'] as List<dynamic>? ?? const <dynamic>[]);
    final List<dynamic> rawSuggestions =
        (json['suggestions'] as List<dynamic>? ?? const <dynamic>[]);

    return AnalysisResult(
      id: json['id'] as String?,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      githubAnalysis: _asMap(json['github_analysis']),
      linkedinAnalysis: _asMap(json['linkedin_analysis']),
      skillGaps: rawSkillGaps
          .whereType<Map<dynamic, dynamic>>()
          .map(_normalizeMap)
          .map(SkillGap.fromJson)
          .toList(growable: false),
      suggestions: rawSuggestions
          .whereType<Map<dynamic, dynamic>>()
          .map(_normalizeMap)
          .map(Suggestion.fromJson)
          .toList(growable: false),
    );
  }

  /// Persisted-row id; `null` for envelopes that haven't been stored yet.
  final String? id;

  /// Server timestamp for the persisted row; `null` for un-persisted
  /// envelopes.
  final DateTime? createdAt;

  /// Free-form GitHub analysis object the LLM produced.
  final Map<String, dynamic> githubAnalysis;

  /// Free-form LinkedIn analysis object the LLM produced.
  final Map<String, dynamic> linkedinAnalysis;

  /// Strongly-typed skill gaps.
  final List<SkillGap> skillGaps;

  /// Strongly-typed suggestions.
  final List<Suggestion> suggestions;
}

/// Body of `POST /api/v1/analysis/run`.
@immutable
class AnalysisRequest {
  const AnalysisRequest({
    required this.githubUrl,
    required this.linkedinUrl,
    required this.goal,
  });

  final String githubUrl;
  final String linkedinUrl;
  final String goal;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'github_url': githubUrl,
        'linkedin_url': linkedinUrl,
        'goal': goal,
      };
}

/// View of `GET /api/v1/profile/settings`.
///
/// Mirrors the `SettingsOut` Pydantic schema. Per Property 18 / Req 6.6
/// this view never carries the AI key in any form.
@immutable
class Settings {
  const Settings({
    required this.hasAiKey,
    required this.aiProviderBaseUrl,
  });

  factory Settings.fromJson(Map<String, dynamic> json) {
    return Settings(
      hasAiKey: json['has_ai_key'] as bool,
      aiProviderBaseUrl: json['ai_provider_base_url'] as String,
    );
  }

  final bool hasAiKey;
  final String aiProviderBaseUrl;

  Settings copyWith({bool? hasAiKey, String? aiProviderBaseUrl}) {
    return Settings(
      hasAiKey: hasAiKey ?? this.hasAiKey,
      aiProviderBaseUrl: aiProviderBaseUrl ?? this.aiProviderBaseUrl,
    );
  }
}

/// Body of `PUT /api/v1/profile/settings`.
@immutable
class SettingsInput {
  const SettingsInput({
    required this.aiKey,
    required this.aiProviderBaseUrl,
  });

  final String aiKey;
  final String aiProviderBaseUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ai_key': aiKey,
        'ai_provider_base_url': aiProviderBaseUrl,
      };
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value == null) {
    return const <String, dynamic>{};
  }
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return _normalizeMap(value);
  }
  throw FormatException(
    'Expected JSON object, got ${value.runtimeType}',
  );
}

Map<String, dynamic> _normalizeMap(Map<dynamic, dynamic> raw) {
  return raw.map<String, dynamic>(
    (Object? key, Object? value) => MapEntry<String, dynamic>(
      key.toString(),
      value,
    ),
  );
}
