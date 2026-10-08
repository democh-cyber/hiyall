import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
const devLoginEnabled = kDebugMode && bool.fromEnvironment('ENABLE_DEV_LOGIN');

class ApiFailure implements Exception {
  final String message;
  final int? status;
  const ApiFailure(this.message, [this.status]);
  @override
  String toString() => message;
}

class ProfileLanguage {
  final String code, level;
  const ProfileLanguage(this.code, [this.level = '']);
  factory ProfileLanguage.fromJson(Object value) => value is String
      ? ProfileLanguage(value)
      : ProfileLanguage(
          (value as Map<String, dynamic>)['code'] as String,
          value['level'] as String? ?? '',
        );
  Map<String, String> toJson() => {
    'code': code,
    if (level.isNotEmpty) 'level': level,
  };
}

/// Display data only. Account identities, credentials and wallet data are never
/// parsed into the profile used by either owner or visitor presentation.
class ProfileSocialStats {
  final int friends, following, followers;
  const ProfileSocialStats({
    required this.friends,
    required this.following,
    required this.followers,
  });
  factory ProfileSocialStats.fromJson(Map<String, dynamic> json) =>
      ProfileSocialStats(
        friends: json['friends'] as int,
        following: json['following'] as int,
        followers: json['followers'] as int,
      );
}

class Profile {
  final String userId, username, displayName, bio, profession, version;
  final String headline, quote, currentVibe, pronouns, education;
  final ProfileSocialStats? socialStats;
  final String profileAccent, profilePattern, avatarFrame;
  final String? country, websiteUrl;
  final List<String> interests;
  final List<ProfileLanguage> languages;
  const Profile({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.bio,
    required this.profession,
    required this.version,
    this.headline = '',
    this.quote = '',
    this.socialStats,
    this.currentVibe = '',
    this.pronouns = '',
    this.education = '',
    this.country,
    this.websiteUrl,
    this.interests = const [],
    this.languages = const [],
    this.profileAccent = 'lime',
    this.profilePattern = 'glow',
    this.avatarFrame = 'minimal',
  });
  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    userId: json['userId'] as String,
    username: json['username'] as String,
    displayName: json['displayName'] as String,
    bio: json['bio'] as String? ?? '',
    profession: json['profession'] as String? ?? '',
    version: json['version'] as String? ?? '',
    headline: json['headline'] as String? ?? '',
    quote: json['quote'] as String? ?? '',
    socialStats: json['socialStats'] == null
        ? null
        : ProfileSocialStats.fromJson(
            json['socialStats'] as Map<String, dynamic>,
          ),
    currentVibe: json['currentVibe'] as String? ?? '',
    pronouns: json['pronouns'] as String? ?? '',
    education: json['education'] as String? ?? '',
    country: json['country'] as String?,
    websiteUrl: json['websiteUrl'] as String?,
    interests: List<String>.unmodifiable(
      (json['interests'] as List? ?? []).cast<String>(),
    ),
    languages: List<ProfileLanguage>.unmodifiable(
      (json['languages'] as List? ?? []).map(
        (v) => ProfileLanguage.fromJson(v as Object),
      ),
    ),
    profileAccent: json['profileAccent'] as String? ?? 'lime',
    profilePattern: json['profilePattern'] as String? ?? 'glow',
    avatarFrame: json['avatarFrame'] as String? ?? 'minimal',
  );
}

class Privacy {
  final Map<String, dynamic> values;
  Privacy(Map<String, dynamic> values)
    : values = Map.unmodifiable({
        ...values,
        'fieldAudiences': Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(values['fieldAudiences'] as Map),
        ),
      });
  String get version => values['version'] as String;
  String text(String key) => values[key] as String;
  bool flag(String key) => values[key] as bool;
}

class Session {
  final String token, userId;
  const Session(this.token, this.userId);
}

class ApiClient {
  final Dio _dio;
  ApiClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: apiBaseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              contentType: 'application/json',
            ),
          );
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    String? version,
  }) async {
    final url = Uri.tryParse(_dio.options.baseUrl);
    if (url == null ||
        url.host.isEmpty ||
        (!devLoginEnabled && url.scheme != 'https')) {
      throw const ApiFailure('The service is not configured yet.');
    }
    if (devLoginEnabled &&
        url.scheme != 'https' &&
        !(url.scheme == 'http' &&
            ['localhost', '127.0.0.1', '10.0.2.2'].contains(url.host))) {
      throw const ApiFailure('Development login requires a local service.');
    }
    try {
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: body,
        options: Options(
          method: method,
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            if (version != null) 'If-Match': '"$version"',
          },
        ),
      );
      return response.data!['data'];
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final message = switch (status) {
        401 => 'Your session has expired. Sign in again.',
        404 => 'This profile is unavailable.',
        409 => 'That username is already taken.',
        412 => 'Your settings changed. Reload before saving.',
        422 => 'Check your entries and try again.',
        429 => 'Please wait a moment and try again.',
        _ => 'Could not connect. Check your connection and retry.',
      };
      throw ApiFailure(message, status);
    }
  }

  Future<Session> signInDevelopment(String userId) async {
    if (!devLoginEnabled) {
      throw const ApiFailure('Development login is disabled.');
    }
    final data = await _request(
      'POST',
      '/dev/session',
      body: {'userId': userId},
    ) as Map<String, dynamic>;
    return Session(data['accessToken'] as String, data['userId'] as String);
  }

  Future<Profile> profile(Session s) async => Profile.fromJson(
    await _request('GET', '/v1/me/profile', token: s.token)
        as Map<String, dynamic>,
  );
  Future<Profile> updateProfile(
    Session s,
    Profile p,
    Map<String, dynamic> patch,
  ) async => Profile.fromJson(
    await _request(
      'PATCH',
      '/v1/me/profile',
      token: s.token,
      version: p.version,
      body: patch,
    ) as Map<String, dynamic>,
  );
  Future<Privacy> privacy(Session s) async => Privacy(
    await _request('GET', '/v1/me/privacy', token: s.token)
        as Map<String, dynamic>,
  );
  Future<Privacy> updatePrivacy(
    Session s,
    Privacy p,
    Map<String, dynamic> patch,
  ) async => Privacy(
    await _request(
      'PATCH',
      '/v1/me/privacy',
      token: s.token,
      version: p.version,
      body: patch,
    ) as Map<String, dynamic>,
  );
  Future<Profile> otherProfile(Session s, String userId) async =>
      Profile.fromJson(
        await _request('GET', '/v1/users/$userId/profile', token: s.token)
            as Map<String, dynamic>,
      );
  Future<void> block(Session s, String userId, bool blocked) async =>
      await _request(
        blocked ? 'POST' : 'DELETE',
        '/v1/users/$userId/block',
        token: s.token,
      );
  Future<Map<String, dynamic>> searchPeople(
    Session session,
    Map<String, dynamic> filters,
  ) async {
    try {
      return await _request(
        'POST',
        '/v1/discovery/search',
        token: session.token,
        body: filters,
      ) as Map<String, dynamic>;
    } on ApiFailure catch (error) {
      if (error.status == 403) {
        throw const ApiFailure(
          'Discovery is available after adult eligibility is confirmed. Age confirmation is not available in this build yet.',
          403,
        );
      }
      rethrow;
    }
  }

  Future<void> logout(Session s) async =>
      await _request('POST', '/v1/auth/logout', token: s.token);
  Future<Map<String, dynamic>> sessions(
    Session s, [
    String? cursor,
  ]) async => await _request(
    'GET',
    '/v1/auth/sessions${cursor == null ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'}',
    token: s.token,
  ) as Map<String, dynamic>;
  Future<void> revokeSession(Session s, String id) async =>
      await _request('DELETE', '/v1/auth/sessions/$id', token: s.token);
}
