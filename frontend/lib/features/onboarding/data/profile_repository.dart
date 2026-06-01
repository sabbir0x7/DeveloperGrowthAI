/// HTTP repository for the user's profile.
///
/// Wraps the `/api/v1/profile/me` endpoints behind a small, typed
/// surface so the `ProfileNotifier` (in `presentation/providers.dart`)
/// stays free of Dio details.
///
/// All requests go through the shared Dio instance built by
/// `core/dio_client.dart`, which attaches the Supabase JWT and handles
/// 401 refresh-then-logout transparently.
library;

import 'package:dio/dio.dart';

import '../domain/profile.dart';

/// Talks to `GET /api/v1/profile/me` and `PATCH /api/v1/profile/me`.
class ProfileRepository {
  /// Creates a repository that issues requests through [dio].
  const ProfileRepository(this._dio);

  final Dio _dio;

  /// Fetches the current user's profile.
  ///
  /// Throws a [DioException] on transport failures and HTTP errors
  /// other than the ones the interceptor already handles (i.e. 401 is
  /// transparently refreshed).
  Future<Profile> getMe() async {
    final Response<dynamic> response =
        await _dio.get<dynamic>('/api/v1/profile/me');
    final Map<String, dynamic> body = _asMap(response.data);
    return Profile.fromJson(body);
  }

  /// Sends a partial update of the current user's profile and returns
  /// the merged profile from the backend.
  Future<Profile> patchMe(ProfilePatch patch) async {
    final Response<dynamic> response = await _dio.patch<dynamic>(
      '/api/v1/profile/me',
      data: patch.toJson(),
    );
    final Map<String, dynamic> body = _asMap(response.data);
    return Profile.fromJson(body);
  }

  /// Defensively coerces a Dio response body into `Map<String, dynamic>`.
  ///
  /// Dio decodes JSON for us when the server returns
  /// `application/json`, but the static type is `dynamic`, so we narrow
  /// it here in one place.
  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return data.map<String, dynamic>(
        (Object? key, Object? value) => MapEntry<String, dynamic>(
          key.toString(),
          value,
        ),
      );
    }
    throw FormatException(
      'Expected JSON object for profile, got ${data.runtimeType}',
    );
  }
}
