import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'realtime/realtime_client.dart';

part 'pulse.dart';
part 'spaces.dart';

const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
const devLoginEnabled = kDebugMode && bool.fromEnvironment('ENABLE_DEV_LOGIN');

class ApiFailure implements Exception {
  final String message;
  final int? status;
  final String? code;
  const ApiFailure(this.message, [this.status, this.code]);
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

/// The viewer's connection to another account, as computed by the server.
class Relationship {
  final String following; // none, pending, active
  final bool followedBy, canFollow, canFriendRequest;
  final String friendship; // none, pending_outgoing, pending_incoming, accepted
  final String? friendRequestId;

  /// The viewer's own private controls on this person; never shown to them.
  final bool muted, restricted;
  const Relationship({
    this.following = 'none',
    this.followedBy = false,
    this.friendship = 'none',
    this.friendRequestId,
    this.canFollow = false,
    this.canFriendRequest = false,
    this.muted = false,
    this.restricted = false,
  });
  factory Relationship.fromJson(Map<String, dynamic> json) => Relationship(
    following: json['following'] as String? ?? 'none',
    followedBy: json['followedBy'] as bool? ?? false,
    friendship: json['friendship'] as String? ?? 'none',
    friendRequestId: json['friendRequestId'] as String?,
    canFollow: json['canFollow'] as bool? ?? false,
    canFriendRequest: json['canFriendRequest'] as bool? ?? false,
    muted: json['muted'] as bool? ?? false,
    restricted: json['restricted'] as bool? ?? false,
  );
  Relationship copyWith({
    String? following,
    String? friendship,
    String? Function()? friendRequestId,
    bool? muted,
    bool? restricted,
  }) => Relationship(
    following: following ?? this.following,
    followedBy: followedBy,
    friendship: friendship ?? this.friendship,
    friendRequestId: friendRequestId == null
        ? this.friendRequestId
        : friendRequestId(),
    canFollow: canFollow,
    canFriendRequest: canFriendRequest,
    muted: muted ?? this.muted,
    restricted: restricted ?? this.restricted,
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

  /// Present only when viewing someone else.
  final Relationship? relationship;

  /// The owner's profile audience excludes this viewer; only identity is sent.
  final bool locked;
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
    this.relationship,
    this.locked = false,
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
    relationship: json['relationship'] == null
        ? null
        : Relationship.fromJson(json['relationship'] as Map<String, dynamic>),
    locked: json['locked'] as bool? ?? false,
  );
}

/// One page of a cursor-paginated list.
class ApiPage<T> {
  final List<T> items;
  final String? nextCursor;
  const ApiPage(this.items, this.nextCursor);
  factory ApiPage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) item,
  ) => ApiPage([
    for (final v in json['items'] as List) item(v as Map<String, dynamic>),
  ], json['nextCursor'] as String?);
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

const _policyCodes = {
  'FOLLOW_NOT_ALLOWED',
  'REQUEST_NOT_ALLOWED',
  'REQUEST_COOLDOWN',
  'CONNECTIONS_PRIVATE',
  'RATE_LIMITED',
  'COMMENTS_NOT_ALLOWED',
  'MEDIA_NOT_READY',
  'MEDIA_UNAVAILABLE',
  'UNSUPPORTED_MEDIA',
  'TOO_LARGE',
  'SPACE_CLOSED',
  'SPACE_FULL',
  'SPACE_OWNER',
  'SPACE_ROLE_REQUIRED',
  'SPACE_MEMBER_REQUIRED',
  'ADULT_SPACE_REQUIRED',
};

/// Reported on sign-in so the sessions list can say where each one is.
String get clientPlatform => kIsWeb
    ? 'web'
    : switch (defaultTargetPlatform) {
        TargetPlatform.android => 'android',
        TargetPlatform.iOS => 'ios',
        _ => 'unknown',
      };

class ApiClient with PulseApi, SpacesApi {
  final Dio _dio;

  /// Sends photo bytes straight to object storage; no API base URL or token.
  @override
  final Dio _uploads = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(minutes: 2),
    ),
  );

  /// Called when a signed-in request is refused as unauthenticated: the
  /// session expired or was revoked elsewhere.
  void Function()? onUnauthorized;
  ApiClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: apiBaseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              contentType: 'application/json',
              headers: {'X-Client-Platform': clientPlatform},
            ),
          );
  @override
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
      final body = error.response?.data;
      final failure = body is Map && body['error'] is Map
          ? body['error'] as Map
          : const {};
      final code = failure['code'] as String?;
      if (status == 401 && token != null) onUnauthorized?.call();
      // Policy refusals carry server copy written to be shown as-is.
      if ((_policyCodes.contains(code) ||
              (path.startsWith('/v1/spaces') && code == 'VALIDATION')) &&
          failure['message'] is String) {
        throw ApiFailure(failure['message'] as String, status, code);
      }
      final message = switch (status) {
        401 => 'Your session has expired. Sign in again.',
        404 =>
          path.startsWith('/v1/spaces')
              ? 'This space is unavailable.'
              : 'This profile is unavailable.',
        409 => 'That username is already taken.',
        412 => 'Your settings changed. Reload before saving.',
        422 => 'Check your entries and try again.',
        429 => 'Please wait a moment and try again.',
        _ => 'Could not connect. Check your connection and retry.',
      };
      throw ApiFailure(message, status, code);
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

  /// Signs out every other session; returns how many ended.
  Future<int> revokeOtherSessions(Session s) async =>
      (await _request('POST', '/v1/auth/sessions/revoke-others', token: s.token)
              as Map<String, dynamic>)['revoked']
          as int;

  /// The account's live event socket, or null where only polling is used.
  RealtimeClient? realtime(Session s) => kIsWeb || _dio.options.baseUrl.isEmpty
      ? null
      : RealtimeClient(_dio.options.baseUrl, s.token);

  // Social graph. Each call returns the server's resulting state.
  Future<String> follow(Session s, String userId) async =>
      (await _request('POST', '/v1/users/$userId/follow', token: s.token)
              as Map<String, dynamic>)['following']
          as String;
  Future<void> unfollow(Session s, String userId) async =>
      await _request('DELETE', '/v1/users/$userId/follow', token: s.token);
  Future<String> sendFriendRequest(Session s, String userId) async =>
      (await _request(
            'POST',
            '/v1/users/$userId/friend-requests',
            token: s.token,
          ) as Map<String, dynamic>)['requestId']
          as String;
  Future<void> cancelFriendRequest(Session s, String requestId) async =>
      await _request(
        'DELETE',
        '/v1/friend-requests/$requestId',
        token: s.token,
      );
  Future<void> respondFriendRequest(
    Session s,
    String requestId,
    bool accept,
  ) async => await _request(
    'POST',
    '/v1/friend-requests/$requestId/${accept ? 'accept' : 'decline'}',
    token: s.token,
  );
  Future<void> unfriend(Session s, String userId) async =>
      await _request('DELETE', '/v1/users/$userId/friendship', token: s.token);
  Future<void> respondFollowRequest(
    Session s,
    String followerId,
    bool accept,
  ) async => accept
      ? await _request(
          'POST',
          '/v1/users/$followerId/follow-requests/accept',
          token: s.token,
        )
      : await _request(
          'DELETE',
          '/v1/me/follow-requests/$followerId',
          token: s.token,
        );

  // Activity.
  Future<(ApiPage<Map<String, dynamic>>, int)> notifications(
    Session s, [
    String? cursor,
  ]) async {
    final data = await _request(
      'GET',
      '/v1/notifications${cursor == null ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'}',
      token: s.token,
    ) as Map<String, dynamic>;
    return (ApiPage.fromJson(data, (v) => v), data['unreadCount'] as int? ?? 0);
  }

  Future<int> unreadNotifications(Session s) async =>
      (await _request('GET', '/v1/notifications/unread-count', token: s.token)
              as Map<String, dynamic>)['unreadCount']
          as int;
  Future<void> markNotificationRead(Session s, String id) async =>
      await _request('POST', '/v1/notifications/$id/read', token: s.token);
  Future<void> markAllNotificationsRead(Session s) async =>
      await _request('POST', '/v1/notifications/read-all', token: s.token);

  /// Mutes someone's notifications, until [until] or indefinitely.
  Future<void> setMuted(
    Session s,
    String userId,
    bool muted, {
    DateTime? until,
  }) async => await _request(
    muted ? 'POST' : 'DELETE',
    '/v1/users/$userId/mute',
    token: s.token,
    body: muted && until != null
        ? {'until': until.toUtc().toIso8601String()}
        : null,
  );

  Future<void> setRestricted(Session s, String userId, bool restricted) async =>
      await _request(
        restricted ? 'POST' : 'DELETE',
        '/v1/users/$userId/restrict',
        token: s.token,
      );

  /// The caller's [kind] list: blocked, muted or restricted.
  Future<ApiPage<Map<String, dynamic>>> controls(
    Session s,
    String kind, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/me/$kind${cursor == null ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'}',
      token: s.token,
    ) as Map<String, dynamic>,
    (v) => v,
  );

  /// Files a report. [evidence] is only what the reporter picked to share,
  /// with [disclosureConsent] confirming it. Returns whether they're now blocked.
  Future<ReportReceipt> report(
    Session s, {
    required String targetType,
    required String targetId,
    required String reasonCode,
    String description = '',
    List<Map<String, dynamic>> evidence = const [],
    bool disclosureConsent = false,
    bool block = false,
  }) async {
    final data = await _request(
      'POST',
      '/v1/reports',
      token: s.token,
      body: {
        'targetType': targetType,
        'targetId': targetId,
        'reasonCode': reasonCode,
        if (description.trim().isNotEmpty) 'description': description.trim(),
        if (evidence.isNotEmpty) ...{
          'evidence': evidence,
          'disclosureConsent': disclosureConsent,
        },
        if (block) 'block': true,
      },
    ) as Map<String, dynamic>;
    return ReportReceipt(
      duplicate: data['duplicate'] as bool? ?? false,
      blocked: data['blocked'] as bool? ?? false,
    );
  }

  Future<ApiPage<Map<String, dynamic>>> myReports(
    Session s, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/me/reports${cursor == null ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'}',
      token: s.token,
    ) as Map<String, dynamic>,
    (v) => v,
  );
}

class ReportReceipt {
  final bool duplicate, blocked;
  const ReportReceipt({this.duplicate = false, this.blocked = false});
}
