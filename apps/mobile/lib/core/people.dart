part of 'api.dart';

/// One row of a followers or following list or of a story's viewers: a person
/// and when the connection began.
class Connection {
  final Person user;
  final DateTime since;

  /// The signed-in member's own follow state on [user] (none, pending, active).
  /// Story viewer rows do not carry it.
  final String following;
  const Connection(this.user, this.since, [this.following = 'none']);
  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
    Person.fromJson(json['user'] as Map),
    DateTime.parse(json['since'] as String),
    json['following'] as String? ?? 'none',
  );
  Connection withFollowing(String state) => Connection(user, since, state);
}

/// A member who opened the signed-in member's profile.
class Visitor {
  final Person user;

  /// When they first opened it; later visits do not move it.
  final DateTime firstVisitedAt;

  /// The signed-in member's own follow state on [user] (none, pending, active).
  final String following;
  const Visitor(this.user, this.firstVisitedAt, [this.following = 'none']);
  factory Visitor.fromJson(Map<String, dynamic> json) => Visitor(
    Person.fromJson(json['user'] as Map),
    DateTime.parse(json['firstVisitedAt'] as String),
    json['following'] as String? ?? 'none',
  );
  Visitor withFollowing(String state) => Visitor(user, firstVisitedAt, state);
}

/// Lists behind the tappable profile stats, mixed into [ApiClient] so tests can
/// override them. Every list is paged by the server's signed cursor; the server
/// decides who may read which.
mixin PeopleApi {
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    // ignore: unused_element_parameter
    Object? body,
    // ignore: unused_element_parameter
    String? version,
  });

  /// `followers` or `following`, newest first: the caller's own, or another
  /// member's when [userId] is given (the server refuses with CONNECTIONS_PRIVATE
  /// unless that member lets the caller see them).
  Future<ApiPage<Connection>> connections(
    Session s,
    String kind, {
    String? userId,
    String? cursor,
  }) async => ApiPage.fromJson(
    await _request(
      'GET',
      '${userId == null ? '/v1/me' : '/v1/users/$userId'}/$kind${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    Connection.fromJson,
  );

  /// People waiting for the caller's approval to follow them.
  Future<ApiPage<Connection>> followRequests(
    Session s, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/me/follow-requests${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    Connection.fromJson,
  );

  /// Drops an active follower without blocking them.
  Future<void> removeFollower(Session s, String userId) async =>
      await _request('DELETE', '/v1/me/followers/$userId', token: s.token);

  /// Who opened the caller's own profile, newest first visit first.
  Future<ApiPage<Visitor>> visitors(Session s, [String? cursor]) async =>
      ApiPage.fromJson(
        await _request(
          'GET',
          '/v1/me/visitors${_cursorQuery(cursor)}',
          token: s.token,
        ) as Map<String, dynamic>,
        Visitor.fromJson,
      );

  /// The caller's own active stories, newest first, each with its view count.
  Future<ApiPage<Story>> myStories(Session s, [String? cursor]) async =>
      ApiPage.fromJson(
        await _request(
          'GET',
          '/v1/me/stories${_cursorQuery(cursor)}',
          token: s.token,
        ) as Map<String, dynamic>,
        Story.fromJson,
      );

  /// The active stories of another member that the caller may watch, newest first.
  Future<ApiPage<Story>> userStories(
    Session s,
    String userId, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/users/$userId/stories?limit=50${_cursorQuery(cursor, '&')}',
      token: s.token,
    ) as Map<String, dynamic>,
    Story.fromJson,
  );
}
