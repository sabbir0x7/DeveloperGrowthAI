/// Domain model for the authenticated user's profile.
///
/// Mirrors the `ProfileOut` Pydantic schema in `backend/app/schemas/
/// profile.py` (see design.md). Only the fields the Flutter app actually
/// reads or writes are modelled here; additional columns can be added
/// alongside their backend counterparts without breaking callers.
library;

import 'package:flutter/foundation.dart';

/// A snapshot of the current user's profile as returned by
/// `GET /api/v1/profile/me`.
///
/// All onboarding fields ([githubUrl], [linkedinUrl], [goal]) are
/// nullable: a fresh user starts with none of them set, and the
/// Route_Guard uses their nullness to drive onboarding redirects.
@immutable
class Profile {
  /// Creates a profile snapshot.
  const Profile({
    required this.id,
    required this.email,
    this.fullName,
    this.githubUrl,
    this.linkedinUrl,
    this.goal,
    this.createdAt,
  });

  /// Builds a [Profile] from a JSON map returned by the backend.
  ///
  /// Tolerates missing optional keys so older API versions or partial
  /// payloads do not throw.
  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      githubUrl: json['github_url'] as String?,
      linkedinUrl: json['linkedin_url'] as String?,
      goal: json['goal'] as String?,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }

  /// The Supabase auth user id (UUID). Equal to `auth.uid()` in SQL.
  final String id;

  /// The user's verified email address.
  final String email;

  /// Optional full name copied from the auth provider, if available.
  final String? fullName;

  /// The user's public GitHub URL. `null` until the user finishes the
  /// Connect Profiles onboarding step.
  final String? githubUrl;

  /// The user's public LinkedIn URL. `null` until the user finishes the
  /// Connect Profiles onboarding step.
  final String? linkedinUrl;

  /// The user's free-text career goal, max 500 chars. `null` until the
  /// user finishes the Set Goal onboarding step.
  final String? goal;

  /// When the user row was first created.
  final DateTime? createdAt;

  /// Returns a copy of this profile with the supplied fields replaced.
  ///
  /// A non-null replacement value overwrites the existing field; a
  /// `null` replacement leaves the existing field untouched. This
  /// matches the merge semantics of `PATCH /profile/me` so the
  /// `ProfileNotifier` can locally apply the patch it just sent.
  Profile copyWith({
    String? githubUrl,
    String? linkedinUrl,
    String? goal,
    String? fullName,
  }) {
    return Profile(
      id: id,
      email: email,
      fullName: fullName ?? this.fullName,
      githubUrl: githubUrl ?? this.githubUrl,
      linkedinUrl: linkedinUrl ?? this.linkedinUrl,
      goal: goal ?? this.goal,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Profile &&
          other.id == id &&
          other.email == email &&
          other.fullName == fullName &&
          other.githubUrl == githubUrl &&
          other.linkedinUrl == linkedinUrl &&
          other.goal == goal &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
        id,
        email,
        fullName,
        githubUrl,
        linkedinUrl,
        goal,
        createdAt,
      );
}

/// Body of a `PATCH /api/v1/profile/me` request.
///
/// Mirrors the `ProfilePatch` Pydantic schema. All fields are optional;
/// `toJson` only serializes the ones the caller actually set, so the
/// backend treats the patch as a partial update.
@immutable
class ProfilePatch {
  const ProfilePatch({
    this.githubUrl,
    this.linkedinUrl,
    this.goal,
    this.linkedinPdfText,
  });

  final String? githubUrl;
  final String? linkedinUrl;
  final String? goal;
  final String? linkedinPdfText;

  /// Serializes only the non-null fields, so the backend can do a
  /// partial update without resetting unspecified columns to null.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> json = <String, dynamic>{};
    if (githubUrl != null) json['github_url'] = githubUrl;
    if (linkedinUrl != null) json['linkedin_url'] = linkedinUrl;
    if (goal != null) json['goal'] = goal;
    if (linkedinPdfText != null) json['linkedin_pdf_text'] = linkedinPdfText;
    return json;
  }
}
