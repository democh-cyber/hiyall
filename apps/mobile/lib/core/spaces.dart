part of 'api.dart';

class SocialSpace {
  final String spaceId, kind, title, description, rules, visibility, status;
  final String myRole, myState, myRsvp, timezone, location;
  final String? parentId;
  final Person owner;
  final int capacity, memberCount;
  final DateTime createdAt;
  final DateTime? startsAt, endsAt;
  final bool canDiscuss;
  const SocialSpace({
    required this.spaceId,
    required this.kind,
    required this.title,
    required this.owner,
    required this.createdAt,
    this.description = '',
    this.rules = '',
    this.visibility = 'public',
    this.status = 'open',
    this.myRole = '',
    this.myState = '',
    this.myRsvp = '',
    this.timezone = 'UTC',
    this.location = '',
    this.parentId,
    this.capacity = 50,
    this.memberCount = 1,
    this.startsAt,
    this.endsAt,
    this.canDiscuss = false,
  });
  factory SocialSpace.fromJson(Map<String, dynamic> j) => SocialSpace(
    spaceId: j['spaceId'] as String,
    kind: j['kind'] as String,
    title: j['title'] as String,
    owner: Person.fromJson(j['owner'] as Map),
    createdAt: DateTime.parse(j['createdAt'] as String),
    description: j['description'] as String? ?? '',
    rules: j['rules'] as String? ?? '',
    visibility: j['visibility'] as String,
    status: j['status'] as String,
    myRole: j['myRole'] as String? ?? '',
    myState: j['myState'] as String? ?? '',
    myRsvp: j['myRsvp'] as String? ?? '',
    timezone: j['timezone'] as String? ?? 'UTC',
    location: j['location'] as String? ?? '',
    parentId: j['parentId'] as String?,
    capacity: j['capacity'] as int,
    memberCount: j['memberCount'] as int,
    startsAt: j['startsAt'] == null
        ? null
        : DateTime.parse(j['startsAt'] as String),
    endsAt: j['endsAt'] == null ? null : DateTime.parse(j['endsAt'] as String),
    canDiscuss: j['canDiscuss'] as bool? ?? false,
  );
  bool get joined => myState == 'active';
  bool get host => joined && (myRole == 'owner' || myRole == 'admin');
  bool get moderate => host || joined && myRole == 'moderator';
}

class SpaceMember {
  final Person user;
  final String role, state, rsvp;
  const SpaceMember(this.user, this.role, this.state, this.rsvp);
  factory SpaceMember.fromJson(Map<String, dynamic> j) => SpaceMember(
    Person.fromJson(j['user'] as Map),
    j['role'] as String,
    j['state'] as String,
    j['rsvp'] as String,
  );
}

class SpaceEntry {
  final String entryId, body;
  final Person author;
  final DateTime createdAt;
  final bool canDelete;
  const SpaceEntry(
    this.entryId,
    this.body,
    this.author,
    this.createdAt,
    this.canDelete,
  );
  factory SpaceEntry.fromJson(Map<String, dynamic> j) => SpaceEntry(
    j['entryId'] as String,
    j['body'] as String,
    Person.fromJson(j['author'] as Map),
    DateTime.parse(j['createdAt'] as String),
    j['canDelete'] as bool,
  );
}

mixin SpacesApi {
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    // ignore: unused_element_parameter
    String? version,
  });
  Future<ApiPage<SocialSpace>> spaces(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/spaces?kind=$kind&mine=$mine${parentId == null ? '' : '&parentId=${Uri.encodeQueryComponent(parentId)}'}${_cursorQuery(cursor, '&')}',
      token: s.token,
    ) as Map<String, dynamic>,
    SocialSpace.fromJson,
  );
  Future<SocialSpace> space(Session s, String id) async => SocialSpace.fromJson(
    await _request('GET', '/v1/spaces/$id', token: s.token)
        as Map<String, dynamic>,
  );
  Future<SocialSpace> createSpace(Session s, Map<String, dynamic> body) async =>
      SocialSpace.fromJson(
        await _request('POST', '/v1/spaces', token: s.token, body: body)
            as Map<String, dynamic>,
      );
  Future<SocialSpace> updateSpace(
    Session s,
    String id,
    Map<String, dynamic> body,
  ) async => SocialSpace.fromJson(
    await _request('PUT', '/v1/spaces/$id', token: s.token, body: body)
        as Map<String, dynamic>,
  );
  Future<SocialSpace> spaceMembership(
    Session s,
    String id, {
    bool join = true,
    String rsvp = 'going',
  }) async => SocialSpace.fromJson(
    await _request(
      join ? 'PUT' : 'DELETE',
      '/v1/spaces/$id/membership',
      token: s.token,
      body: join ? {'rsvp': rsvp} : null,
    ) as Map<String, dynamic>,
  );
  Future<SocialSpace> spaceStatus(Session s, String id, String status) async =>
      SocialSpace.fromJson(
        await _request(
          'PUT',
          '/v1/spaces/$id/status',
          token: s.token,
          body: {'status': status},
        ) as Map<String, dynamic>,
      );
  Future<ApiPage<SpaceMember>> spaceMembers(
    Session s,
    String id, {
    String state = 'active',
    String? cursor,
  }) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/spaces/$id/members?state=$state${_cursorQuery(cursor, '&')}',
      token: s.token,
    ) as Map<String, dynamic>,
    SpaceMember.fromJson,
  );
  Future<void> inviteSpaceUser(Session s, String id, String username) async {
    await _request(
      'POST',
      '/v1/spaces/$id/invitations',
      token: s.token,
      body: {'username': username},
    );
  }

  Future<void> spaceMemberAction(
    Session s,
    String id,
    String user,
    String action,
  ) async {
    await _request(
      'PUT',
      '/v1/spaces/$id/members/$user',
      token: s.token,
      body: {'action': action},
    );
  }

  Future<ApiPage<SpaceEntry>> spaceEntries(
    Session s,
    String id, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/spaces/$id/entries${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    SpaceEntry.fromJson,
  );
  Future<void> addSpaceEntry(Session s, String id, String text) async {
    await _request(
      'POST',
      '/v1/spaces/$id/entries',
      token: s.token,
      body: {'body': text},
    );
  }

  Future<void> deleteSpaceEntry(Session s, String id, String entry) async {
    await _request('DELETE', '/v1/spaces/$id/entries/$entry', token: s.token);
  }
}
