import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat/chat_api.dart' show ChatFailure;
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_groups.dart';
import '../core/chat/chat_text.dart' show sanitizeText;
import 'chat.dart' show chatEngineProvider;
import 'live_sync.dart' show chatSignalProvider;

// Data and wording behind the group chat screens (docs/mobile/19-group-chat.md): the providers the Chats list,
// the thread and Group info read, how a group is shown as a row of the chat list, and what each refusal says.

/// A failed read is shown by the screen that asked, never retried in the background: a retry timer would also
/// outlive a widget test.
Duration? _noRetry(int attempt, Object error) => null;

/// The groups of this account's chat list (not deleted), refreshed by the same signals as the one-to-one list.
final groupsProvider = FutureProvider<List<GroupInfo>>((ref) async {
  final engine = await ref.watch(chatEngineProvider.future);
  ref.watch(chatSignalProvider);
  if (engine == null) return const [];
  return engine.groups();
}, retry: _noRetry);

/// Invitations waiting for an answer.
final groupInvitesProvider = FutureProvider<List<GroupInvite>>((ref) async {
  final engine = await ref.watch(chatEngineProvider.future);
  ref.watch(chatSignalProvider);
  if (engine == null) return const [];
  return engine.groupInvites();
}, retry: _noRetry);

/// One group with its members, pending invites and unconfirmed members.
final groupInfoProvider = FutureProvider.autoDispose.family<GroupInfo, String>((
  ref,
  id,
) async {
  final engine = await ref.watch(chatEngineProvider.future);
  ref.watch(chatSignalProvider);
  if (engine == null) {
    throw const ChatFailure('NOT_FOUND', 'This group isn’t available.');
  }
  return engine.group(id);
}, retry: _noRetry);

/// What the screens need to draw one person of a group: a name and a photo.
class GroupPerson {
  final String id, name;
  final String? avatarUrl;
  const GroupPerson(this.id, this.name, [this.avatarUrl]);
}

/// Who is who in a group, for the names above bubbles, in quotes and on reactions: the members now, the people
/// invited, and the people who left or were removed, whose names the engine kept ([ChatEngine.groupDirectory]).
class GroupDirectory {
  static const former = 'Former member';
  final Map<String, GroupPerson> _people;
  const GroupDirectory._(this._people);
  static const empty = GroupDirectory._({});

  factory GroupDirectory.of(
    GroupInfo? group, {
    Map<String, GroupMember> known = const {},
  }) {
    final people = <String, GroupPerson>{
      for (final m in known.values)
        m.userId: GroupPerson(m.userId, displayName(m.name), m.avatarUrl),
    };
    for (final p in group?.pending ?? const <GroupPending>[]) {
      people[p.userId] = GroupPerson(
        p.userId,
        displayName(p.name),
        p.avatarUrl,
      );
    }
    for (final m in group?.members ?? const <GroupMember>[]) {
      people[m.userId] = GroupPerson(
        m.userId,
        displayName(m.name),
        m.avatarUrl,
      );
    }
    return GroupDirectory._(people);
  }

  /// The person with this id; someone this phone has no name for is a [former] member.
  GroupPerson of(String id) => _people[id] ?? GroupPerson(id, former);
  bool knows(String id) => _people.containsKey(id);
}

/// A name from the relay or a member, for drawing: one line, without control characters.
String displayName(String name) {
  final clean = sanitizeText(name, multiline: false).trim();
  return clean.isEmpty ? 'Someone' : clean;
}

/// The first word of a name: "Sam" for "Sam Rivera".
String firstName(String name) {
  final clean = displayName(name);
  final first = clean.split(RegExp(r'\s+')).first;
  return first.isEmpty ? clean : first;
}

/// The group's name, else the first names of the people in it other than [me] ("Sam, Kai, Mia +2").
String groupTitle(GroupInfo g, String me) {
  final own = sanitizeText(g.name, multiline: false).trim();
  if (own.isNotEmpty) return own;
  final others = [
    for (final m in g.members)
      if (m.userId != me) firstName(m.name),
  ];
  if (others.isEmpty) return 'Group';
  return others.length <= 3
      ? others.join(', ')
      : '${others.take(3).join(', ')} +${others.length - 3}';
}

/// The title of an invitation: the group's name, else the people already in it.
String inviteTitle(GroupInvite i) {
  final own = sanitizeText(i.name, multiline: false).trim();
  if (own.isNotEmpty) return own;
  final names = [for (final m in i.members) firstName(m.name)];
  return names.isEmpty ? 'Group' : names.take(3).join(', ');
}

/// "1 member", "7 members".
String memberCountText(int n) => n == 1 ? '1 member' : '$n members';

/// The members to draw as a stack of up to three photos: the people other than [me] first (their own photo is
/// the least interesting one in a group), else [me].
List<GroupMember> stackMembers(GroupInfo g, String me, {int max = 3}) {
  final others = [
    for (final m in g.members)
      if (m.userId != me) m,
  ];
  final pool = others.isEmpty ? g.members : others;
  return pool.take(max).toList();
}

/// A group as a row of the chat list: the list, its search, its unread filter, its selection and its pin, mute
/// and delete actions all work on [ChatConversation], so a group is one with no peer. The username holds the
/// members' names so a search finds a group by who is in it.
ChatConversation groupAsConversation(GroupInfo g, String me) =>
    ChatConversation(
      g.id,
      '',
      groupTitle(g, me),
      [for (final m in g.members) '${m.username} ${m.displayName}'].join(' '),
      g.last,
      unreadCount: g.unreadCount,
      mutedUntil: g.mutedUntil,
      pinnedAt: g.pinnedAt,
      hiddenAt: g.hiddenAt,
      restoreUntil: g.restoreUntil,
    );

DateTime _activity(ChatConversation c, Map<String, GroupInfo> groups) =>
    c.last?.at ??
    groups[c.id]?.lastMessageAt ??
    groups[c.id]?.createdAt ??
    DateTime.fromMillisecondsSinceEpoch(0);

/// One-to-one chats and groups in one list: pinned first, then the newest activity first. Each input list keeps
/// its own order (the relay sorts it); the two are merged by looking at their heads.
List<ChatConversation> mergeChats(
  List<ChatConversation> chats,
  List<GroupInfo> groups,
  String me,
) {
  if (groups.isEmpty) return chats;
  final byId = {for (final g in groups) g.id: g};
  final asChats = [for (final g in groups) groupAsConversation(g, me)];
  bool before(ChatConversation a, ChatConversation b) {
    if (a.pinned != b.pinned) return a.pinned;
    if (a.pinned && b.pinned) return a.pinnedAt!.isAfter(b.pinnedAt!);
    return _activity(a, byId).isAfter(_activity(b, byId));
  }

  final out = <ChatConversation>[];
  var i = 0, j = 0;
  while (i < chats.length && j < asChats.length) {
    // Ties keep the one-to-one chat first, so nothing moves in a list without groups.
    out.add(before(asChats[j], chats[i]) ? asChats[j++] : chats[i++]);
  }
  out
    ..addAll(chats.skip(i))
    ..addAll(asChats.skip(j));
  return out;
}

// ------------------------------------------------------------------ errors

/// What a refused group call says, or null when [error] is not one of the group refusals. [name] is the person the
/// call was about, when the caller knows it. A refusal to add someone never says why: a block, an age band, a
/// privacy choice and a full list of groups all read the same.
String? groupFailureText(Object error, {String? name}) {
  if (error is! ChatFailure) return null;
  final who = name == null || name.trim().isEmpty ? null : name.trim();
  return switch (error.code) {
    'CANNOT_ADD_MEMBER' =>
      '${who ?? 'That person'} can’t be added to this group.',
    'GROUP_FULL' => 'This group is full. A group has up to 10 people, counting invites that haven’t been answered.',
    'GROUP_LIMIT' => 'You’re in as many groups as you can be. Leave one to start or join another.',
    'DAILY_LIMIT' => 'You’ve reached today’s limit for groups and invites. Try again tomorrow.',
    'GROUP_NOT_OWNER' => 'Only the owner of the group can do that.',
    'GROUP_WAITING' => 'Waiting for others to join.',
    'GROUP_UNCONFIRMED_MEMBER' => 'Someone in this group isn’t confirmed on this phone yet, so nothing was sent. Open Group info to confirm them.',
    'GROUP_OUT_OF_SYNC' =>
      error.message.trim().isEmpty
          ? 'The member list changed while sending. Nothing was sent. Try again in a moment.'
          : error.message,
    _ => null,
  };
}

/// The person a [ChatFailure] `CANNOT_ADD_MEMBER` names (`details.userId`), or null.
String? cannotAddUserId(Object error) {
  if (error is ChatFailure && error.code == 'CANNOT_ADD_MEMBER') {
    final id = error.details?['userId'];
    if (id is String && id.isNotEmpty) return id;
  }
  return null;
}
