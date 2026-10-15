import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_config.dart';
import 'app_info.dart';
import 'badge.dart';
import 'discovery.dart';
import 'presence.dart';
import 'realtime/realtime_client.dart';

export 'badge.dart' show UnreadBadge, badgeLabel;

part 'pulse.dart';
part 'spaces.dart';
part 'nearby.dart';
part 'people.dart';
part 'account.dart';

const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// Sent on every API call with [AppInfo.version] (`MAJOR.MINOR.PATCH`).
const clientVersionHeader = 'X-Client-Version';

/// With HTTP 426, the server's answer to a version it no longer accepts.
const upgradeRequiredCode = 'UPGRADE_REQUIRED';

class ApiFailure implements Exception {
  final String message;
  final int? status;
  final String? code;

  /// How long the server said a limit lasts (Retry-After), when it said.
  final Duration? retryAfter;
  const ApiFailure(this.message, [this.status, this.code, this.retryAfter]);

  /// The words to show. A daily limit (code QUOTA) that says when it lifts trades the server's
  /// "Try again later." for "Try again in about 5 hours."; every other failure is [message].
  String get displayMessage {
    final wait = retryAfter;
    const later = ' Try again later.';
    if (code != 'QUOTA' || wait == null || !message.endsWith(later)) {
      return message;
    }
    final head = message.substring(0, message.length - later.length);
    final minutes = (wait.inSeconds / 60).ceil();
    final about = minutes < 90
        ? (minutes <= 1 ? 'a minute' : '$minutes minutes')
        : (() {
            final hours = (minutes / 60).round();
            return hours == 1 ? 'an hour' : '$hours hours';
          })();
    return '$head Try again in about $about.';
  }

  @override
  String toString() => displayMessage;
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
  final int following, followers;

  /// How many different members have opened this profile. Never who.
  final int visitors;

  /// Stories up right now that the viewer may watch.
  final int stories;

  /// Friendships still exist on the server but are no longer shown.
  final int friends;
  const ProfileSocialStats({
    this.friends = 0,
    required this.following,
    required this.followers,
    this.visitors = 0,
    this.stories = 0,
  });
  factory ProfileSocialStats.fromJson(Map<String, dynamic> json) =>
      ProfileSocialStats(
        friends: json['friends'] as int? ?? 0,
        following: json['following'] as int? ?? 0,
        followers: json['followers'] as int? ?? 0,
        visitors: json['visitors'] as int? ?? 0,
        stories: json['stories'] as int? ?? 0,
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

  /// `woman`, `man`, `nonbinary`, or empty when not said.
  final String gender;

  /// Whole years, present only when the server chose to show it to this viewer.
  final int? age;

  /// Where they say they are, beyond the country (both optional).
  final String region, city;
  final ProfileSocialStats? socialStats;
  final String profileAccent, profilePattern, avatarFrame;
  final String? country, websiteUrl;
  final List<String> interests;

  /// In people lists only: up to three interests this member shares with the
  /// viewer, spelled as the viewer wrote them. The server sends it only when the
  /// member shows their interests, so empty means "nothing to say", not "none".
  final List<String> sharedInterests;
  final List<ProfileLanguage> languages;

  /// Present only when viewing someone else.
  final Relationship? relationship;

  /// The owner's profile audience excludes this viewer; only identity is sent.
  final bool locked;

  /// Whether the viewer may open this member's followers and following lists.
  /// Only sent with someone else's profile; false when the server did not say.
  final bool canSeeConnections;

  /// Set only when the person is online and lets this viewer see it: true while
  /// they are, false never. Null means "not shared", so no dot is drawn.
  final bool? online;

  /// When they were last seen (UTC, a five-minute bucket), only when they are
  /// not online and the server let this viewer see it; null otherwise.
  final DateTime? lastSeenAt;

  /// Rounded-up distance bucket, present only in nearby results.
  final int? distanceKm;

  /// Signed photo URLs, null when they have no photo. The thumbnail is on every
  /// person; the full size only on the owner's and a visitor's profile. They
  /// expire after about an hour, so images are cached by path, never by URL.
  final String? avatarUrl, avatarFullUrl;
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
    this.gender = '',
    this.age,
    this.region = '',
    this.city = '',
    this.country,
    this.websiteUrl,
    this.interests = const [],
    this.sharedInterests = const [],
    this.languages = const [],
    this.profileAccent = 'lime',
    this.profilePattern = 'glow',
    this.avatarFrame = 'minimal',
    this.relationship,
    this.locked = false,
    this.canSeeConnections = false,
    this.online,
    this.lastSeenAt,
    this.distanceKm,
    this.avatarUrl,
    this.avatarFullUrl,
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
    gender: json['gender'] as String? ?? '',
    age: (json['age'] as num?)?.toInt(),
    region: json['region'] as String? ?? '',
    city: json['city'] as String? ?? '',
    country: json['country'] as String?,
    websiteUrl: json['websiteUrl'] as String?,
    interests: List<String>.unmodifiable(
      (json['interests'] as List? ?? []).cast<String>(),
    ),
    sharedInterests: List<String>.unmodifiable(
      [
        for (final v in json['sharedInterests'] as List? ?? const [])
          if (v is String && v.trim().isNotEmpty) v,
      ].take(3),
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
    canSeeConnections: json['canSeeConnections'] as bool? ?? false,
    online: json['online'] is bool ? json['online'] as bool : null,
    lastSeenAt: parseLastSeen(json['lastSeenAt']),
    distanceKm: (json['distanceKm'] as num?)?.toInt(),
    avatarUrl: json['avatarUrl'] as String?,
    avatarFullUrl: json['avatarFullUrl'] as String?,
  );

  /// The photo suited to a circle of [diameter] logical pixels: the full-size
  /// one for a large header when the server sent it, the thumbnail otherwise.
  String? avatarFor(double diameter) =>
      diameter >= 96 ? (avatarFullUrl ?? avatarUrl) : avatarUrl;
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
  final String userId;
  final String _token;
  final String Function()? _live;

  /// False until the account has finished onboarding (age confirmation, terms,
  /// name and username). The API refuses most routes until it is true.
  final bool onboarded;

  /// [live] returns the newest token when the identity provider rotates it, so
  /// long-lived callers such as the realtime socket never hold an expired one.
  const Session(
    this._token,
    this.userId, {
    String Function()? live,
    this.onboarded = true,
  }) : _live = live; // ignore: prefer_initializing_formals
  String get token => _live?.call() ?? _token;
  Session copyWith({bool? onboarded}) => Session(
    _token,
    userId,
    live: _live,
    onboarded: onboarded ?? this.onboarded,
  );
}

class OnboardingStatus {
  final bool completed;

  /// The terms revision the server expects the person to accept.
  final String termsVersion;
  const OnboardingStatus(this.completed, this.termsVersion);
  factory OnboardingStatus.fromJson(Map<String, dynamic> json) =>
      OnboardingStatus(
        json['completed'] as bool? ?? false,
        json['termsVersion'] as String? ?? '',
      );
}

const _policyCodes = {
  'FOLLOW_NOT_ALLOWED',
  'REQUEST_NOT_ALLOWED',
  'REQUEST_COOLDOWN',
  'CONNECTIONS_PRIVATE',
  'RATE_LIMITED',
  'QUOTA',
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
  'EMAIL_NOT_VERIFIED',
  'LOCATION_NOT_SHARED',
  'ONBOARDING_REQUIRED',
  'AGE_REQUIREMENT_NOT_MET',
  'PROFILE_INCOMPLETE',
  'INVALID_CURSOR',
  'REAUTH_REQUIRED',
  'DELETION_WINDOW_CLOSED',
};

/// Reported on sign-in so the sessions list can say where each one is.
String get clientPlatform => kIsWeb
    ? 'web'
    : switch (defaultTargetPlatform) {
        TargetPlatform.android => 'android',
        TargetPlatform.iOS => 'ios',
        _ => 'unknown',
      };

class ApiClient with PulseApi, SpacesApi, NearbyApi, PeopleApi, AccountApi {
  final Dio _dio;

  /// Sends photo bytes straight to object storage; no API base URL or token.
  @override
  final Dio _uploads;

  /// Called when a signed-in request is refused as unauthenticated: the
  /// session expired or was revoked elsewhere.
  void Function()? onUnauthorized;

  /// Called after a follow went through (push notifications ask for permission then).
  void Function()? onFollowed;

  /// Asks the identity provider for a brand-new token after a 401. A different
  /// token means the first was only stale, so the request is retried once.
  Future<String?> Function()? tokenRefresher;
  ApiClient({Dio? dio, Dio? uploads})
    : _uploads =
          uploads ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(minutes: 2),
            ),
          ),
      _dio =
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

  /// Called when the server refuses this app version (426 UPGRADE_REQUIRED);
  /// the app then shows only the "Update Hiyall" screen.
  void Function()? onUpgradeRequired;
  @override
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    String? version,
    bool retried = false,
    bool bytes = false,
    Duration? receiveTimeout,
  }) async {
    // Release builds talk https only; debug builds may use this machine's own API.
    if (!isSecureTransport(Uri.tryParse(_dio.options.baseUrl))) {
      throw const ApiFailure('The service is not configured yet.');
    }
    try {
      final options = Options(
        method: method,
        responseType: bytes ? ResponseType.bytes : null,
        receiveTimeout: receiveTimeout,
        headers: {
          clientVersionHeader: AppInfo.version,
          if (token != null) 'Authorization': 'Bearer $token',
          if (version != null) 'If-Match': '"$version"',
        },
      );
      if (bytes) {
        // A raw download (the data export): the body is the payload, not an envelope.
        final response = await _dio.request<List<int>>(
          path,
          data: body,
          options: options,
        );
        return response.data ?? const <int>[];
      }
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: body,
        options: options,
      );
      return response.data!['data'];
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      var reply = error.response?.data;
      if (reply is List<int>) {
        // A failed raw download still answers with the JSON error envelope.
        try {
          reply = jsonDecode(utf8.decode(reply));
        } catch (_) {
          reply = null;
        }
      }
      final failure = reply is Map && reply['error'] is Map
          ? reply['error'] as Map
          : const {};
      final code = failure['code'] as String?;
      if (status == 401 && token != null && !retried) {
        final fresh = await tokenRefresher?.call();
        if (fresh != null && fresh != token) {
          return _request(
            method,
            path,
            token: fresh,
            body: body,
            version: version,
            retried: true,
            bytes: bytes,
            receiveTimeout: receiveTimeout,
          );
        }
      }
      if (status == 401 && token != null) onUnauthorized?.call();
      if (status == 426 && code == upgradeRequiredCode) {
        onUpgradeRequired?.call();
        throw ApiFailure(
          'This version of Hiyall is no longer supported. Update to keep going.',
          status,
          code,
        );
      }
      // Policy refusals carry server copy written to be shown as-is.
      if ((_policyCodes.contains(code) ||
              (path == '/v1/me/deletion' && code == 'VALIDATION') ||
              (path.startsWith('/v1/spaces') && code == 'VALIDATION')) &&
          failure['message'] is String) {
        throw ApiFailure(
          failure['message'] as String,
          status,
          code,
          _retryAfter(error),
        );
      }
      throw ApiFailure(
        failureMessage(error.type, status, code, path),
        status,
        code ?? transportCode(error.type, status),
        status == 429 ? _retryAfter(error) : null,
      );
    }
  }

  static Duration? _retryAfter(DioException error) {
    final wait = int.tryParse(
      error.response?.headers.value('retry-after') ?? '',
    );
    return wait == null || wait < 1 ? null : Duration(seconds: wait);
  }

  /// `TIMEOUT` or `OFFLINE` when no answer came back, so callers (and tests)
  /// can tell those apart from a server failure.
  static String? transportCode(DioExceptionType type, int? status) {
    if (status != null) return null;
    return switch (type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'TIMEOUT',
      DioExceptionType.connectionError => 'OFFLINE',
      _ => null,
    };
  }

  /// Words for a failure the server did not word itself, chosen by status,
  /// error code and endpoint. Never the exception's own text.
  static String failureMessage(
    DioExceptionType type,
    int? status,
    String? code,
    String path,
  ) {
    if (status == null) {
      return switch (transportCode(type, status)) {
        'TIMEOUT' => 'Hiyall is taking too long to answer. Try again.',
        'OFFLINE' => 'You’re offline. Check your connection and try again.',
        _ => 'Could not connect. Check your connection and retry.',
      };
    }
    if (status >= 500) {
      return 'Something went wrong on our side. Try again in a moment.';
    }
    final p = path.split('?').first;
    return switch (status) {
      401 => 'Your session has expired. Sign in again.',
      403 => 'You can’t do that here.',
      404 => switch (p) {
        _ when p.startsWith('/v1/spaces') => 'This space is unavailable.',
        _ when p.startsWith('/v1/posts') || p.startsWith('/v1/pulse') =>
          'This post is no longer available.',
        _ when p.startsWith('/v1/stories') =>
          'This story is no longer available.',
        _ when p.startsWith('/v1/users/') && p.endsWith('/profile') =>
          'This profile is unavailable.',
        _ when p.startsWith('/v1/auth/sessions') =>
          'That session has already ended.',
        _ when p.startsWith('/v1/friend-requests') =>
          'That request is no longer open.',
        _ when p.startsWith('/v1/notifications') =>
          'That notification is gone.',
        _ when p.startsWith('/v1/users/') => 'This account is unavailable.',
        _ => 'That’s no longer available.',
      },
      409 =>
        code == 'USERNAME_TAKEN'
            ? 'That username is already taken.'
            : 'That changed in the meantime. Refresh and try again.',
      412 => 'Your settings changed. Reload before saving.',
      413 => 'That’s too large to send.',
      422 => 'Check your entries and try again.',
      429 when p == '/v1/me/export' =>
        'You can download your data once a day. Try again later.',
      429 => 'Please wait a moment and try again.',
      _ => 'That didn’t work. Try again.',
    };
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

  /// Sets the profile photo to an uploaded media item, or removes it with
  /// null. The server checks the media belongs to the caller.
  Future<Profile> setAvatar(Session s, Profile p, String? mediaId) =>
      updateProfile(s, p, {'avatarMediaId': mediaId});
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
  ) async => await _request(
    'POST',
    '/v1/discovery/search',
    token: session.token,
    body: filters,
  ) as Map<String, dynamic>;

  Future<OnboardingStatus> onboarding(Session s) async =>
      OnboardingStatus.fromJson(
        await _request('GET', '/v1/me/onboarding', token: s.token)
            as Map<String, dynamic>,
      );

  /// Confirms the minimum-age declaration and terms. The birth date is checked by the
  /// server and never stored.
  Future<OnboardingStatus> completeOnboarding(
    Session s, {
    required String birthDate,
    required String termsVersion,
  }) async => OnboardingStatus.fromJson(
    await _request(
      'POST',
      '/v1/me/onboarding/complete',
      token: s.token,
      body: {'birthDate': birthDate, 'termsVersion': termsVersion},
    ) as Map<String, dynamic>,
  );

  /// Sends the declared birth date as soon as it is chosen. The server
  /// refuses a date under 13 (AGE_REQUIREMENT_NOT_MET) and remembers the
  /// refusal against the sign-in for 7 days (AGE_GATE_COOLDOWN). Nothing is
  /// stored for an accepted date; it is stored when onboarding completes.
  Future<void> checkBirthDate(Session s, String birthDate) async =>
      await _request(
        'POST',
        '/v1/me/onboarding/age',
        token: s.token,
        body: {'birthDate': birthDate},
      );

  Future<bool> usernameAvailable(Session s, String username) async =>
      (await _request(
            'GET',
            '/v1/usernames/${Uri.encodeComponent(username)}/availability',
            token: s.token,
          ) as Map<String, dynamic>)['available']
          as bool;

  Future<void> logout(Session s) async =>
      await _request('POST', '/v1/auth/logout', token: s.token);

  /// Revokes a session left over from an offline sign-out. Bypasses the token
  /// refresher and the unauthorized hook on purpose: the old token belongs to
  /// no current session, and a 401 must not end the one signed in now.
  Future<RevokeOutcome> revokeQueuedSession(String token) async {
    try {
      await _dio.post<Object?>(
        '/v1/auth/logout',
        options: Options(
          headers: {
            clientVersionHeader: AppInfo.version,
            'Authorization': 'Bearer $token',
          },
        ),
      );
      return RevokeOutcome.revoked;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == null || status >= 500) return RevokeOutcome.unreachable;
      return RevokeOutcome.gone;
    } catch (_) {
      return RevokeOutcome.gone;
    }
  }

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
      : RealtimeClient(
          _dio.options.baseUrl,
          s.token,
          tokenOf: () => s.token,
          refreshToken: () async => tokenRefresher?.call(),
          onSessionEnded: () => onUnauthorized?.call(),
        );

  // Social graph. Each call returns the server's resulting state.
  Future<String> follow(Session s, String userId) async {
    final state =
        (await _request('POST', '/v1/users/$userId/follow', token: s.token)
                as Map<String, dynamic>)['following']
            as String;
    onFollowed?.call();
    return state;
  }

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
  Future<(ApiPage<Map<String, dynamic>>, UnreadBadge)> notifications(
    Session s, [
    String? cursor,
  ]) async {
    final data = await _request(
      'GET',
      '/v1/notifications${cursor == null ? '' : '?cursor=${Uri.encodeQueryComponent(cursor)}'}',
      token: s.token,
    ) as Map<String, dynamic>;
    return (ApiPage.fromJson(data, (v) => v), UnreadBadge.fromJson(data));
  }

  Future<UnreadBadge> unreadNotifications(Session s) async =>
      UnreadBadge.fromJson(
        await _request('GET', '/v1/notifications/unread-count', token: s.token)
            as Map<String, dynamic>,
      );
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

/// What happened to a queued sign-out: done, already over (401 and other
/// refusals), or not sent because the server could not be reached.
enum RevokeOutcome { revoked, gone, unreachable }

class ReportReceipt {
  final bool duplicate, blocked;
  const ReportReceipt({this.duplicate = false, this.blocked = false});
}
