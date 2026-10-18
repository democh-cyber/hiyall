import 'chat_engine.dart' show ChatMessage;

/// The peer id the engine's one-to-one entry points (`send`, `sendPhoto`, `react` ...) take for a group chat.
/// The engine knows a group by its conversation id ([ChatEngine.isGroup]); the peer argument is ignored.
const groupPeer = '';

/// The longest group name, in characters (the relay enforces it too).
const groupNameMax = 40;

/// Most people in a group, pending invites included (the relay enforces it; this is only for the picker).
const groupMembersMax = 10;

/// One person in a group, as the relay lists them.
class GroupMember {
  final String userId, username, displayName;
  final String? avatarUrl;
  final bool owner;
  final DateTime? joinedAt;
  const GroupMember({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.owner = false,
    this.joinedAt,
  });

  /// What to call this person: their display name, else their username.
  String get name => displayName.trim().isEmpty ? username : displayName;

  /// The relay's own shape, which [parse] reads back (the phone keeps people who left in this form).
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
    'displayName': displayName,
    'avatarUrl': ?avatarUrl,
    'role': owner ? 'owner' : 'member',
    if (joinedAt != null) 'joinedAt': joinedAt!.toUtc().toIso8601String(),
  };

  static GroupMember? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['userId'];
    if (id is! String || id.isEmpty) return null;
    return GroupMember(
      userId: id,
      username: raw['username'] as String? ?? '',
      displayName: raw['displayName'] as String? ?? '',
      avatarUrl: raw['avatarUrl'] as String?,
      owner: raw['role'] == 'owner',
      joinedAt: DateTime.tryParse('${raw['joinedAt']}'),
    );
  }
}

/// A person who has been invited and has not answered yet.
class GroupPending {
  final String userId, username, displayName;
  final String? avatarUrl;
  final DateTime? invitedAt, expiresAt;
  const GroupPending({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.invitedAt,
    this.expiresAt,
  });
  String get name => displayName.trim().isEmpty ? username : displayName;

  static GroupPending? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['userId'];
    if (id is! String || id.isEmpty) return null;
    return GroupPending(
      userId: id,
      username: raw['username'] as String? ?? '',
      displayName: raw['displayName'] as String? ?? '',
      avatarUrl: raw['avatarUrl'] as String?,
      invitedAt: DateTime.tryParse('${raw['invitedAt']}'),
      expiresAt: DateTime.tryParse('${raw['expiresAt']}'),
    );
  }
}

/// A server-recorded membership event (see docs/api/29-group-chat.md).
class GroupEvent {
  final String eventId, kind;
  final String? actorId, subjectId, messageId, name;
  final DateTime at;
  const GroupEvent({
    required this.eventId,
    required this.kind,
    required this.at,
    this.actorId,
    this.subjectId,
    this.messageId,
    this.name,
  });

  static GroupEvent? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['eventId'], kind = raw['kind'];
    final at = DateTime.tryParse('${raw['at']}');
    if (id is! String || kind is! String || at == null) return null;
    return GroupEvent(
      eventId: id,
      kind: kind,
      at: at,
      actorId: raw['actorId'] as String?,
      subjectId: raw['subjectId'] as String?,
      messageId: raw['messageId'] as String?,
      name: raw['name'] as String?,
    );
  }
}

/// A group in the chat list or open on screen: the relay's view (members, pending invites, per-member flags) with
/// the last message from this phone's own history.
class GroupInfo {
  /// The group id, which is also its conversation id for messages, blobs, read pointers, mute, pin and hide.
  final String id;

  /// The group name; empty when it has none (use [title]).
  final String name;
  final String ownerId;

  /// The relay closed the group (fewer than two active members).
  final bool closed;

  /// This account is no longer in the group: it was removed, left, or the group closed. Read-only.
  final bool readOnly;

  /// Active members the caller can see, the caller included, in joining order (the owner first).
  final List<GroupMember> members;

  /// People invited and not yet joined. Listed to members.
  final List<GroupPending> pending;
  final int unreadCount;
  final DateTime? lastMessageAt, mutedUntil, pinnedAt, hiddenAt, restoreUntil;
  final DateTime createdAt;

  /// The last message of this group in this phone's history (null when empty).
  final ChatMessage? last;

  /// Members this phone has not accounted for (see docs/mobile/19-group-chat.md, "Membership changes"): listed
  /// by the relay without an authenticated `join`. Nothing is sealed for them until [ChatEngine.confirmGroupMember].
  final Set<String> unconfirmed;

  /// Members the relay still lists although this phone holds a removal mark for them (it was told they were
  /// removed, left, or deleted their account). Nothing is sealed for them; a send stops with
  /// `GROUP_OUT_OF_SYNC` while the relay lists them.
  final Set<String> outOfSync;
  final List<GroupEvent> events;

  /// This account has been invited and has not answered: the relay shows only the name and the members.
  final bool invited;
  const GroupInfo({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.createdAt,
    this.closed = false,
    this.readOnly = false,
    this.members = const [],
    this.pending = const [],
    this.unreadCount = 0,
    this.lastMessageAt,
    this.mutedUntil,
    this.pinnedAt,
    this.hiddenAt,
    this.restoreUntil,
    this.last,
    this.unconfirmed = const {},
    this.outOfSync = const {},
    this.events = const [],
    this.invited = false,
  });

  bool get pinned => pinnedAt != null;
  bool get muted => mutedUntil?.isAfter(DateTime.now()) ?? false;
  int get memberCount => members.length;

  /// Whether [userId] is the owner.
  bool isOwner(String userId) => ownerId == userId;

  /// The member with this id, or null.
  GroupMember? member(String userId) {
    for (final m in members) {
      if (m.userId == userId) return m;
    }
    return null;
  }

  /// The name to show: the group's own, else the names of the first few members other than [me], joined with
  /// commas ("Sam, Kai, Mia"), else "Group".
  String title(String me) {
    if (name.trim().isNotEmpty) return name;
    final others = [
      for (final m in members)
        if (m.userId != me) m.name,
    ];
    if (others.isEmpty) return 'Group';
    return others.length <= 3
        ? others.join(', ')
        : '${others.take(3).join(', ')} +${others.length - 3}';
  }

  GroupInfo copyWith({
    ChatMessage? last,
    int? unreadCount,
    bool? readOnly,
    Set<String>? unconfirmed,
    Set<String>? outOfSync,
    DateTime? hiddenAt,
    DateTime? restoreUntil,
  }) => GroupInfo(
    id: id,
    name: name,
    ownerId: ownerId,
    createdAt: createdAt,
    closed: closed,
    readOnly: readOnly ?? this.readOnly,
    members: members,
    pending: pending,
    unreadCount: unreadCount ?? this.unreadCount,
    lastMessageAt: lastMessageAt,
    mutedUntil: mutedUntil,
    pinnedAt: pinnedAt,
    hiddenAt: hiddenAt ?? this.hiddenAt,
    restoreUntil: restoreUntil ?? this.restoreUntil,
    last: last ?? this.last,
    unconfirmed: unconfirmed ?? this.unconfirmed,
    outOfSync: outOfSync ?? this.outOfSync,
    events: events,
    invited: invited,
  );

  /// Reads the relay's `Group` JSON. Returns null for something that is not one.
  static GroupInfo? parse(
    Object? raw, {
    ChatMessage? last,
    bool readOnly = false,
    Set<String> unconfirmed = const {},
  }) {
    if (raw is! Map) return null;
    final id = raw['groupId'], owner = raw['ownerId'];
    final created = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || owner is! String || created == null) return null;
    final members = <GroupMember>[
      if (raw['members'] is List)
        for (final m in raw['members'] as List) ?GroupMember.parse(m),
    ];
    return GroupInfo(
      id: id,
      name: raw['name'] as String? ?? '',
      ownerId: owner,
      createdAt: created,
      closed: raw['status'] == 'closed',
      readOnly: readOnly || raw['status'] == 'closed',
      members: members,
      pending: [
        if (raw['pending'] is List)
          for (final p in raw['pending'] as List) ?GroupPending.parse(p),
      ],
      unreadCount: raw['unreadCount'] as int? ?? 0,
      lastMessageAt: DateTime.tryParse('${raw['lastMessageAt']}'),
      mutedUntil: DateTime.tryParse('${raw['mutedUntil']}'),
      pinnedAt: DateTime.tryParse('${raw['pinnedAt']}'),
      hiddenAt: DateTime.tryParse('${raw['hiddenAt']}'),
      restoreUntil: DateTime.tryParse('${raw['restoreUntil']}'),
      last: last,
      unconfirmed: unconfirmed,
      events: [
        if (raw['events'] is List)
          for (final e in raw['events'] as List) ?GroupEvent.parse(e),
      ],
      invited: raw['myState'] == 'invited',
    );
  }
}

/// An invitation to a group that this account has not answered. It carries no content.
class GroupInvite {
  final String groupId, name;
  final GroupMember invitedBy;
  final DateTime invitedAt, expiresAt;
  final int memberCount;

  /// People already in the group (names and photos only).
  final List<GroupMember> members;
  const GroupInvite({
    required this.groupId,
    required this.name,
    required this.invitedBy,
    required this.invitedAt,
    required this.expiresAt,
    required this.memberCount,
    this.members = const [],
  });

  /// The name to show: the group's own, else the people already in it.
  String get title {
    if (name.trim().isNotEmpty) return name;
    final names = [for (final m in members) m.name];
    return names.isEmpty ? 'Group' : names.take(3).join(', ');
  }

  static GroupInvite? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['groupId'];
    final by = GroupMember.parse(raw['invitedBy']);
    final invited = DateTime.tryParse('${raw['invitedAt']}');
    final expires = DateTime.tryParse('${raw['expiresAt']}');
    if (id is! String || by == null || invited == null || expires == null) {
      return null;
    }
    return GroupInvite(
      groupId: id,
      name: raw['name'] as String? ?? '',
      invitedBy: by,
      invitedAt: invited,
      expiresAt: expires,
      memberCount: raw['memberCount'] as int? ?? 0,
      members: [
        if (raw['members'] is List)
          for (final m in raw['members'] as List) ?GroupMember.parse(m),
      ],
    );
  }
}
