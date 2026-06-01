/// HTTP repository for the dashboard feature.
///
/// Wraps the `/api/v1/analysis/*` and `/api/v1/profile/settings`
/// endpoints behind a typed surface so the dashboard providers stay
/// free of Dio details.
library;

import 'package:dio/dio.dart';

import '../domain/analysis_models.dart';

/// Indicates the user has not configured an AI key yet.
///
/// The backend signals this with HTTP 412 + `{"code": "ai_key_missing"}`.
/// The dashboard maps this to the Settings drawer "set your key" banner
/// (see Requirement 4.7 + design.md frontend mapping).
class MissingAIKeyException implements Exception {
  const MissingAIKeyException();
  @override
  String toString() => 'AI key not configured.';
}

/// The upstream AI provider returned a non-2xx response. The
/// [upstreamStatus] mirrors the body's `upstream_status` field, when
/// present, for surfacing to the user via the retry CTA.
class UpstreamAIException implements Exception {
  const UpstreamAIException({required this.upstreamStatus});
  final int? upstreamStatus;
  @override
  String toString() =>
      'Upstream AI error (status=${upstreamStatus ?? 'unknown'}).';
}

/// The user has hit the per-user sliding-window rate limit on
/// `/api/v1/analysis/*`. [retryAfterSeconds] mirrors the `Retry-After`
/// response header (or `null` if the server omitted it).
class AnalysisRateLimitedException implements Exception {
  const AnalysisRateLimitedException({this.retryAfterSeconds});
  final int? retryAfterSeconds;
  @override
  String toString() => 'Rate limited; retry after '
      '${retryAfterSeconds ?? 'unknown'}s.';
}

/// Talks to `/api/v1/analysis/*` and `/api/v1/profile/settings`.
class AnalysisRepository {
  /// Creates a repository that issues requests through [dio].
  const AnalysisRepository(this._dio);

  final Dio _dio;

  /// Runs a fresh analysis. Maps backend error codes onto the typed
  /// exceptions above so the UI layer can switch on them directly.
  Future<AnalysisResult> run(AnalysisRequest request) async {
    try {
      final Response<dynamic> response = await _dio.post<dynamic>(
        '/api/v1/analysis/run',
        data: request.toJson(),
      );
      return AnalysisResult.fromJson(_asMap(response.data));
    } on DioException catch (err) {
      _translate(err);
      rethrow;
    }
  }

  /// Returns the latest analysis row for the authenticated user, or
  /// `null` when the user has not run any analyses yet.
  ///
  /// The backend returns 204 (or 200 with an empty body) for the
  /// empty-state case (Requirement 5.5); both shapes resolve to `null`.
  Future<AnalysisResult?> getLatest() async {
    final Response<dynamic> response = await _dio.get<dynamic>(
      '/api/v1/analysis/latest',
      options: Options(
        // 204 must NOT be treated as an error.
        validateStatus: (int? status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    if (response.statusCode == 204 || response.data == null) {
      return null;
    }
    if (response.data is Map && (response.data as Map).isEmpty) {
      return null;
    }
    return AnalysisResult.fromJson(_asMap(response.data));
  }

  /// Reads the user's settings.
  Future<Settings> getSettings() async {
    final Response<dynamic> response =
        await _dio.get<dynamic>('/api/v1/profile/settings');
    return Settings.fromJson(_asMap(response.data));
  }

  /// Saves the user's AI key + provider base URL.
  ///
  /// Returns the refreshed [Settings] so the notifier can update its
  /// state without a separate GET round-trip. The backend's PUT may
  /// return either the new metadata view (`SettingsOut`) or no body;
  /// we synthesize a metadata view in the latter case.
  Future<Settings> putSettings(SettingsInput input) async {
    final Response<dynamic> response = await _dio.put<dynamic>(
      '/api/v1/profile/settings',
      data: input.toJson(),
    );
    final dynamic data = response.data;
    if (data is Map && data.containsKey('has_ai_key')) {
      return Settings.fromJson(_asMap(data));
    }
    return Settings(
      hasAiKey: true,
      aiProviderBaseUrl: input.aiProviderBaseUrl,
    );
  }

  /// Translates a [DioException] from `/analysis/run` into one of the
  /// typed exceptions exported by this file. Returns normally if the
  /// error is not one of the recognized codes; the caller will then
  /// rethrow the original [DioException].
  void _translate(DioException err) {
    final Response<dynamic>? response = err.response;
    if (response == null) {
      return;
    }
    final int? status = response.statusCode;
    final dynamic body = response.data;
    String? code;
    int? upstream;
    int? retryAfter;

    if (body is Map) {
      final dynamic rawCode = body['code'];
      if (rawCode is String) code = rawCode;
      final dynamic rawUpstream = body['upstream_status'];
      if (rawUpstream is int) upstream = rawUpstream;
      if (rawUpstream is String) upstream = int.tryParse(rawUpstream);
    }

    final dynamic rawRetry = response.headers.value('retry-after');
    if (rawRetry is String) retryAfter = int.tryParse(rawRetry);

    if (status == 412 && code == 'ai_key_missing') {
      throw const MissingAIKeyException();
    }
    if (status == 429) {
      throw AnalysisRateLimitedException(retryAfterSeconds: retryAfter);
    }
    if (status == 502) {
      throw UpstreamAIException(upstreamStatus: upstream);
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map<String, dynamic>(
        (Object? key, Object? value) => MapEntry<String, dynamic>(
          key.toString(),
          value,
        ),
      );
    }
    throw FormatException(
      'Expected JSON object, got ${data.runtimeType}',
    );
  }
}
