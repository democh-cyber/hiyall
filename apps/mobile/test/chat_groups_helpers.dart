import 'dart:convert';
import 'dart:io';

import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/src/rust/api/e2ee.dart';

import 'chat_av_helpers.dart' show AvCloud;

// A group-capable relay in memory, for the engine tests of docs/api/29-group-chat.md and
// docs/mobile/19-group-chat.md. It mimics the server's rules that matter to the phones: exact device sets
// (and DEVICES_CHANGED), the `aux` flag on control messages, the roster, invites, accept/leave/remove/rename with
// their control message in the same request, the closing of a group below two active members, the events, and
// one-time key claims. It never sees plaintext. A test can make it lie (list a person who was removed, invent a
// member) by editing [RelayGroup.members] directly.

const aliceId = '019a4000-0000-7000-8000-000000000001';
const bobId = '019a4000-0000-7000-8000-000000000002';
const carolId = '019a4000-0000-7000-8000-000000000003';
const daveId = '019a4000-0000-7000-8000-000000000004';
const malloryId = '019a4000-0000-7000-8000-000000000005';
const groupId = '019a4000-0000-7000-8000-0000000000a1';

String uuid(int n) =>
    '6c6c0000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

const _names = {
  aliceId: ('alice', 'Alice'),
  bobId: ('bob', 'Bob'),
  carolId: ('carol', 'Carol'),
  daveId: ('dave', 'Dave'),
  malloryId: ('mallory', 'Mallory'),
};

class RelayGroup {
  RelayGroup(this.id, this.name, this.ownerId, this.createdAt);
  final String id;
  String name, ownerId;
  String status = 'active';
  final DateTime createdAt;

  /// Active members, in joining order. Edit it to make the relay lie.
  final members = <String>[];
  final joinedAt = <String, DateTime>{};
  final pending = <String, DateTime>{};
  final events = <Map<String, dynamic>>[];
}

class GroupRelay {
  final devices = <String, Map<String, Map<String, dynamic>>>{};
  final keys = <String, Map<String, List<Map<String, String>>>>{};
  final inboxes = <String, List<Map<String, dynamic>>>{};
  final groups = <String, RelayGroup>{};
  final stored = <String, DateTime>{};

  /// Every send or control request as the wire saw it, refused ones included.
  final wire = <WireRequest>[];

  /// Every call, for counting (`group <id>`, `conversation <id>`, ...).
  final calls = <String>[];
  final unread = <String, int>{};
  int clock = 0;
  Object? failNext;

  /// The relay forgets to flag control messages as auxiliary.
  bool stripControlAux = false;

  /// The relay lets a non-owner rename or remove (the phones must not believe it).
  bool skipOwnerCheck = false;
  final cannotAdd = <String>{};
  List<String> closedIds = [];
  final hiddenGroupItems = <String, List<Map<String, dynamic>>>{};

  DateTime tick() => DateTime.utc(2026, 10, 13, 12, 0, clock++);

  int count(String prefix) => calls.where((c) => c.startsWith(prefix)).length;

  Iterable<String> deviceIds(String user) => devices[user]?.keys ?? const [];

  /// Devices a request must carry: every device of the active members the sender can see and of [plus], and
  /// the sender's other devices, never the sending device.
  Set<String> expected(
    RelayGroup g,
    String sender,
    String senderDevice, {
    Iterable<String> plus = const [],
  }) => {
    for (final u in {...g.members, sender, ...plus}) ...deviceIds(u),
  }..remove(senderDevice);

  /// The devices of [user] named in a wire record.
  List<String> wireDevicesFor(WireRequest r, String user) => [
    for (final d in r.devices)
      if (deviceIds(user).contains(d)) d,
  ];

  Map<String, dynamic> event(
    RelayGroup g,
    String kind, {
    String? actor,
    String? subject,
    String? messageId,
    String? name,
  }) {
    final e = {
      'eventId': uuid(9000 + g.events.length + clock),
      'kind': kind,
      'actorId': actor,
      'subjectId': subject,
      'messageId': messageId,
      'name': name,
      'at': tick().toIso8601String(),
    };
    g.events.add(e);
    return e;
  }

  Map<String, dynamic> userJson(String id) => {
    'userId': id,
    'username': _names[id]?.$1 ?? 'user',
    'displayName': _names[id]?.$2 ?? 'User',
    'avatarUrl': null,
  };

  Map<String, dynamic> groupJson(
    RelayGroup g,
    String caller, {
    bool events = true,
  }) {
    final active = g.members.contains(caller);
    return {
      'groupId': g.id,
      'conversationId': g.id,
      'kind': 'group',
      'name': g.name,
      'ownerId': g.ownerId,
      'status': g.status,
      'createdAt': g.createdAt.toIso8601String(),
      'lastMessageAt': null,
      'memberCount': g.members.length,
      'members': [
        for (final m in g.members)
          {
            ...userJson(m),
            'role': m == g.ownerId ? 'owner' : 'member',
            'joinedAt': (g.joinedAt[m] ?? g.createdAt).toIso8601String(),
          },
      ],
      'pending': active
          ? [
              for (final e in g.pending.entries)
                {
                  ...userJson(e.key),
                  'invitedAt': e.value.toIso8601String(),
                  'expiresAt': e.value
                      .add(const Duration(days: 7))
                      .toIso8601String(),
                },
            ]
          : [],
      'myState': active ? 'active' : 'invited',
      'unreadCount': 0,
      'readAt': null,
      'mutedUntil': null,
      'pinnedAt': null,
      'hiddenAt': null,
      'restoreUntil': null,
      'limits': {'maxMembers': 10, 'inviteExpiryDays': 7},
      if (events && active) 'events': [...g.events],
    };
  }

  /// Stores one message for every device in [envelopes]. A control message is flagged auxiliary (unless
  /// [stripControlAux]); so is a reaction or noop the sender flagged.
  DateTime deliver(
    String group,
    String from,
    String senderDevice,
    String messageId,
    List<Map> envelopes, {
    required bool aux,
  }) {
    final at = tick();
    stored[messageId] = at;
    final identity = devices[from]![senderDevice]!['identityKey'];
    for (final e in envelopes) {
      (inboxes[e['deviceId'] as String] ??= []).add({
        'conversationId': group,
        'senderId': from,
        'messageId': messageId,
        'senderDeviceId': senderDevice,
        'senderIdentityKey': identity,
        'type': e['type'],
        'ciphertext': e['ciphertext'],
        if (aux) 'aux': true,
        'createdAt': at.toIso8601String(),
      });
    }
    return at;
  }

  /// A person's undelivered ciphertext for [groupId] is deleted, except the message [keep].
  void purge(String group, String user, {String? keep}) {
    for (final d in deviceIds(user)) {
      inboxes[d]?.removeWhere(
        (m) => m['conversationId'] == group && m['messageId'] != keep,
      );
    }
  }

  /// A group below two active members closes, its invites cancelled.
  void closeIfSmall(RelayGroup g, {bool onlyWithoutInvites = false}) {
    if (onlyWithoutInvites && g.pending.isNotEmpty) return;
    if (g.status == 'active' && g.members.length < 2) {
      g.status = 'closed';
      g.pending.clear();
      event(g, 'closed');
    }
  }

  /// An account is deleted: its devices go, it leaves every group, and each group records the fact.
  void deleteAccount(String user) {
    devices.remove(user);
    keys.remove(user);
    for (final g in groups.values) {
      final was = g.members.remove(user);
      g.pending.remove(user);
      if (!was) continue;
      event(g, 'member_deleted', subject: user);
      if (g.ownerId == user && g.members.isNotEmpty) {
        g.ownerId = g.members.first;
      }
      closeIfSmall(g);
    }
  }
}

/// One request the relay saw.
class WireRequest {
  final String kind, from, group, messageId;
  final bool aux;

  /// The devices that had an envelope in it.
  final List<String> devices;
  const WireRequest(
    this.kind,
    this.from,
    this.group,
    this.messageId,
    this.aux,
    this.devices,
  );
}

class GroupApi extends ChatApi {
  GroupApi(this.relay, this.user, {this.cloud})
    : super('http://127.0.0.1:1', 't');
  final GroupRelay relay;
  final String user;
  final AvCloud? cloud;

  ChatFailure _notFound() => const ChatFailure('NOT_FOUND', 'not found', 404);

  RelayGroup _group(String id) => relay.groups[id] ?? (throw _notFound());

  /// The group for a caller who is an active member, or 404.
  RelayGroup _active(String id) {
    final g = _group(id);
    if (!g.members.contains(user)) throw _notFound();
    return g;
  }

  void _checkDevices(Set<String> expected, List<Map> envelopes) {
    final got = [for (final e in envelopes) e['deviceId'] as String];
    if (got.length != got.toSet().length ||
        got.toSet().length != expected.length ||
        !got.every(expected.contains)) {
      throw const ChatFailure('DEVICES_CHANGED', 'device set', 409);
    }
  }

  // ------------------------------------------------------- devices, keys

  @override
  Future<void> registerDevice(Map<String, String> d) async =>
      (relay.devices[user] ??= {})[d['deviceId']!] = {...d};
  @override
  Future<int> keyCount(String deviceId) async =>
      relay.keys[user]?[deviceId]?.length ?? 0;
  @override
  Future<int> uploadKeys(
    String deviceId,
    List<Map<String, String>> oneTimeKeys,
    Map<String, String>? fallbackKey,
  ) async {
    final held = (relay.keys[user] ??= {})[deviceId] ??= [];
    for (final k in oneTimeKeys) {
      if (held.every((h) => h['keyId'] != k['keyId'])) held.add(k);
    }
    return held.length;
  }

  @override
  Future<List<Map<String, dynamic>>> devices(String userId) async {
    relay.calls.add('devices $userId');
    if (userId.isEmpty) throw _notFound();
    return [
      for (final d in (relay.devices[userId] ?? {}).values) {...d},
    ];
  }

  @override
  Future<Map<String, dynamic>> claim(String userId, String deviceId) async {
    final pool = relay.keys[userId]![deviceId]!;
    return {...pool.removeAt(0), 'fallback': false, 'deviceId': deviceId};
  }

  @override
  Future<List<Map<String, dynamic>>> inbox(String deviceId) async => [
    ...?relay.inboxes[deviceId],
  ];
  @override
  Future<void> ack(String deviceId, List<String> messageIds) async => relay
      .inboxes[deviceId]
      ?.removeWhere((m) => messageIds.contains(m['messageId']));

  // ------------------------------------------------------- conversations

  @override
  Future<void> markRead(String conversationId, DateTime upTo) async {
    relay.calls.add('read $conversationId');
  }

  @override
  Future<Map<String, dynamic>> conversation(String id) async {
    relay.calls.add('conversation $id');
    throw _notFound();
  }

  @override
  Future<List<Map<String, dynamic>>> conversations({int limit = 50}) async =>
      [];

  @override
  Future<({List<Map<String, dynamic>> items, List<String> closedIds})>
  hiddenConversations() async =>
      (items: <Map<String, dynamic>>[], closedIds: relay.closedIds);

  @override
  Future<void> pinConversation(String id, bool pinned) async {
    relay.calls.add('pin $id $pinned');
  }

  @override
  Future<void> hideConversation(String id) async {
    relay.calls.add('hide $id');
  }

  @override
  Future<void> restoreConversation(String id) async {
    relay.calls.add('restore $id');
  }

  // ------------------------------------------------------- blobs

  @override
  Future<BlobSlot> createBlobSlot(
    String conversationId,
    String role,
    int sizeBytes,
    String ctSha256,
  ) => cloud!.createBlobSlot(conversationId, role, sizeBytes, ctSha256);
  @override
  Future<void> completeBlob(String blobId) => cloud!.completeBlob(blobId);
  @override
  Future<void> deleteBlob(String blobId) => cloud!.deleteBlob(blobId);
  @override
  Future<({String url, int? sizeBytes})> blobDownloadUrl(
    String conversationId,
    String blobId,
  ) => cloud!.blobDownloadUrl(conversationId, blobId);

  // ------------------------------------------------------- messages

  @override
  Future<DateTime?> send(
    String conversationId,
    Map<String, dynamic> message, {
    List<String> blobIds = const [],
    bool aux = false,
  }) async {
    final id = message['messageId'] as String;
    final envelopes = (message['envelopes'] as List).cast<Map>();
    relay.wire.add(
      WireRequest('message', user, conversationId, id, aux, [
        for (final e in envelopes) e['deviceId'] as String,
      ]),
    );
    final failure = relay.failNext;
    if (failure != null) {
      relay.failNext = null;
      throw failure;
    }
    final g = _active(conversationId);
    final known = relay.stored[id];
    if (known != null) return known;
    if (g.status == 'closed') {
      throw const ChatFailure('CONVERSATION_CLOSED', 'closed', 403);
    }
    final senderDevice = message['senderDeviceId'] as String;
    if (!g.members.any((m) => m != user && relay.deviceIds(m).isNotEmpty)) {
      throw const ChatFailure('GROUP_WAITING', 'nobody to send to', 409);
    }
    _checkDevices(relay.expected(g, user, senderDevice), envelopes);
    final c = cloud;
    if (c != null) {
      for (final b in blobIds) {
        final s = c.slots[b];
        if (s == null || s.deleted || !s.completed || c.claimed.contains(b)) {
          throw const ChatFailure('BLOB_NOT_READY', 'Finish uploading', 409);
        }
      }
      c.claimed.addAll(blobIds);
    }
    if (aux) {
      for (final e in envelopes) {
        if (base64Decode(base64.normalize(e['ciphertext'] as String)).length >
            2048) {
          throw const ChatFailure('TOO_LARGE', 'too big', 413);
        }
      }
    }
    final at = relay.deliver(
      conversationId,
      user,
      senderDevice,
      id,
      envelopes,
      aux: aux,
    );
    if (!aux) {
      for (final m in g.members.where((m) => m != user)) {
        relay.unread[m] = (relay.unread[m] ?? 0) + 1;
      }
    }
    return at;
  }

  // ------------------------------------------------------- groups

  @override
  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> memberIds,
  ) async {
    relay.calls.add('create');
    for (final m in memberIds) {
      if (relay.cannotAdd.contains(m)) {
        throw ChatFailure('CANNOT_ADD_MEMBER', 'no', 409, null, {'userId': m});
      }
    }
    if (memberIds.length < 2 || memberIds.length > 9) {
      throw const ChatFailure('VALIDATION', 'bad members', 422);
    }
    final id = relay.groups.isEmpty
        ? groupId
        : '019a4000-0000-7000-8000-0000000000a${relay.groups.length + 1}';
    final g = RelayGroup(id, name, user, relay.tick());
    g.members.add(user);
    g.joinedAt[user] = g.createdAt;
    for (final m in memberIds) {
      g.pending[m] = relay.tick();
    }
    relay.groups[id] = g;
    relay.event(g, 'created', actor: user);
    return relay.groupJson(g, user);
  }

  @override
  Future<List<Map<String, dynamic>>> groups() async {
    relay.calls.add('groups');
    return [
      for (final g in relay.groups.values)
        if (g.members.contains(user)) relay.groupJson(g, user, events: false),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> hiddenGroups() async =>
      relay.hiddenGroupItems[user] ?? const [];

  @override
  Future<List<Map<String, dynamic>>> groupInvites() async => [
    for (final g in relay.groups.values)
      if (g.pending.containsKey(user) && g.status == 'active')
        {
          'groupId': g.id,
          'name': g.name,
          'invitedBy': relay.userJson(g.ownerId),
          'invitedAt': g.pending[user]!.toIso8601String(),
          'expiresAt': g.pending[user]!
              .add(const Duration(days: 7))
              .toIso8601String(),
          'memberCount': g.members.length,
          'members': [for (final m in g.members) relay.userJson(m)],
        },
  ];

  @override
  Future<Map<String, dynamic>> group(String id) async {
    relay.calls.add('group $id');
    final g = _group(id);
    if (!g.members.contains(user) && !g.pending.containsKey(user)) {
      throw _notFound();
    }
    return relay.groupJson(g, user);
  }

  @override
  Future<Map<String, dynamic>> inviteToGroup(
    String id,
    List<String> userIds,
  ) async {
    final g = _active(id);
    if (g.ownerId != user) {
      throw const ChatFailure('GROUP_NOT_OWNER', 'owner only', 403);
    }
    for (final u in userIds) {
      if (relay.cannotAdd.contains(u)) {
        throw ChatFailure('CANNOT_ADD_MEMBER', 'no', 409, null, {'userId': u});
      }
      if (g.members.length + g.pending.length >= 10) {
        throw const ChatFailure('GROUP_FULL', 'full', 409);
      }
      if (!g.members.contains(u)) g.pending[u] = relay.tick();
    }
    return relay.groupJson(g, user);
  }

  @override
  Future<Map<String, dynamic>> acceptGroupInvite(
    String id,
    Map<String, dynamic> control,
  ) async {
    final g = _group(id);
    final envelopes = (control['envelopes'] as List).cast<Map>();
    final mid = control['messageId'] as String;
    relay.wire.add(
      WireRequest('accept', user, id, mid, true, [
        for (final e in envelopes) e['deviceId'] as String,
      ]),
    );
    final failure = relay.failNext;
    if (failure != null) {
      relay.failNext = null;
      throw failure;
    }
    if (!g.pending.containsKey(user) || g.status != 'active') throw _notFound();
    _checkDevices(
      relay.expected(g, user, control['senderDeviceId'] as String),
      envelopes,
    );
    relay.deliver(
      id,
      user,
      control['senderDeviceId'] as String,
      mid,
      envelopes,
      aux: !relay.stripControlAux,
    );
    g.pending.remove(user);
    g.members.add(user);
    g.joinedAt[user] = relay.tick();
    relay.event(g, 'joined', actor: user, subject: user, messageId: mid);
    return relay.groupJson(g, user);
  }

  @override
  Future<void> declineGroupInvite(String id) async {
    final g = _group(id);
    if (g.pending.remove(user) == null) throw _notFound();
    relay.closeIfSmall(g, onlyWithoutInvites: true);
  }

  @override
  Future<Map<String, dynamic>> renameGroup(
    String id,
    String name,
    Map<String, dynamic> control,
  ) async {
    final g = _active(id);
    final envelopes = (control['envelopes'] as List).cast<Map>();
    final mid = control['messageId'] as String;
    relay.wire.add(
      WireRequest('rename', user, id, mid, true, [
        for (final e in envelopes) e['deviceId'] as String,
      ]),
    );
    if (g.ownerId != user && !relay.skipOwnerCheck) {
      throw const ChatFailure('GROUP_NOT_OWNER', 'owner only', 403);
    }
    _checkDevices(
      relay.expected(g, user, control['senderDeviceId'] as String),
      envelopes,
    );
    relay.deliver(
      id,
      user,
      control['senderDeviceId'] as String,
      mid,
      envelopes,
      aux: !relay.stripControlAux,
    );
    g.name = name;
    relay.event(g, 'renamed', actor: user, messageId: mid, name: name);
    return relay.groupJson(g, user);
  }

  @override
  Future<Map<String, dynamic>> removeGroupMember(
    String id,
    String userId, {
    Map<String, dynamic>? control,
  }) async {
    final g = _active(id);
    if (g.ownerId != user && !relay.skipOwnerCheck) {
      throw const ChatFailure('GROUP_NOT_OWNER', 'owner only', 403);
    }
    if (control == null) {
      if (g.pending.remove(userId) == null) throw _notFound();
      relay.closeIfSmall(g);
      return relay.groupJson(g, user);
    }
    final envelopes = (control['envelopes'] as List).cast<Map>();
    final mid = control['messageId'] as String;
    relay.wire.add(
      WireRequest('remove', user, id, mid, true, [
        for (final e in envelopes) e['deviceId'] as String,
      ]),
    );
    if (!g.members.contains(userId)) throw _notFound();
    _checkDevices(
      relay.expected(g, user, control['senderDeviceId'] as String),
      envelopes,
    );
    relay.deliver(
      id,
      user,
      control['senderDeviceId'] as String,
      mid,
      envelopes,
      aux: !relay.stripControlAux,
    );
    g.members.remove(userId);
    relay.purge(id, userId, keep: mid);
    relay.event(g, 'removed', actor: user, subject: userId, messageId: mid);
    relay.closeIfSmall(g);
    return relay.groupJson(g, user);
  }

  @override
  Future<void> leaveGroup(
    String id, {
    Map<String, dynamic>? control,
    String? newOwnerId,
  }) async {
    final g = _active(id);
    final others = g.members.where((m) => m != user).toList();
    if (g.ownerId == user && others.length >= 2 && newOwnerId == null) {
      throw const ChatFailure('VALIDATION', 'name a new owner', 422);
    }
    String? mid;
    if (control != null) {
      final envelopes = (control['envelopes'] as List).cast<Map>();
      mid = control['messageId'] as String;
      relay.wire.add(
        WireRequest('leave', user, id, mid, true, [
          for (final e in envelopes) e['deviceId'] as String,
        ]),
      );
      _checkDevices(
        relay.expected(g, user, control['senderDeviceId'] as String),
        envelopes,
      );
      relay.deliver(
        id,
        user,
        control['senderDeviceId'] as String,
        mid,
        envelopes,
        aux: !relay.stripControlAux,
      );
    }
    g.members.remove(user);
    relay.purge(id, user);
    relay.event(g, 'left', actor: user, subject: user, messageId: mid);
    if (g.ownerId == user) {
      final next = newOwnerId ?? (g.members.isEmpty ? null : g.members.first);
      if (next != null) {
        g.ownerId = next;
        relay.event(g, 'owner_changed', actor: user, subject: next);
      }
    }
    relay.closeIfSmall(g);
  }
}

// ------------------------------------------------------- forged senders

/// A raw Olm device that is a member in the relay's eyes and can put any payload, with any `aux` flag and any
/// relay metadata, into a phone's inbox: what a hostile member (or relay) could do.
class RawDevice {
  RawDevice(this.relay, this.userId)
    : deviceId = uuid(7000 + userId.hashCode.abs() % 1000),
      account = OlmAccount.create() {
    (relay.devices[userId] ??= {})[deviceId] = {
      'deviceId': deviceId,
      'identityKey': account.identityKey(),
      'signingKey': account.signingKey(),
      'platform': 'test',
      'signature': account.sign(
        message: deviceStatement(
          userId,
          deviceId,
          account.identityKey(),
          account.signingKey(),
        ),
      ),
      'displayName': '',
    };
  }
  final GroupRelay relay;
  final String userId, deviceId;
  final OlmAccount account;
  final _sessions = <String, OlmSession>{};

  /// Puts [payload] (JSON, sealed with a session to [target]'s device) into its inbox as if the relay had
  /// delivered it from this device of [userId]. [aux] and [senderId] are the relay's metadata.
  void inject(
    ChatEngine target,
    String conversation,
    Map<String, dynamic> payload, {
    required String messageId,
    bool aux = false,
    String? senderId,
  }) {
    var session = _sessions[target.deviceId];
    if (session == null) {
      final pool = relay.keys[target.userId]![target.deviceId]!;
      session = _sessions[target.deviceId] = account.createOutbound(
        identityKey: target.identityKey,
        oneTimeKey: pool.removeAt(0)['publicKey']!,
      );
    }
    final sealed = session.encrypt(plaintext: jsonEncode(payload));
    (relay.inboxes[target.deviceId] ??= []).add({
      'conversationId': conversation,
      'senderId': senderId ?? userId,
      'messageId': messageId,
      'senderDeviceId': deviceId,
      'senderIdentityKey': account.identityKey(),
      'type': sealed.messageType,
      'ciphertext': sealed.ciphertext,
      if (aux) 'aux': true,
      'createdAt': relay.tick().toIso8601String(),
    });
  }

  /// A membership payload as this member's phone would write it.
  Map<String, dynamic> control(
    String conversation,
    String messageId,
    String op, {
    String? subject,
    String? name,
    String? owner,
    String? senderId,
  }) => {
    'v': 1,
    'kind': 'group',
    'text': '',
    'op': op,
    'subject': ?subject,
    'name': ?name,
    'owner': ?owner,
    'messageId': messageId,
    'conversationId': conversation,
    'senderId': senderId ?? userId,
    'sentAt': DateTime.utc(2026, 10, 13, 12, 0, 1).toIso8601String(),
  };
}

// ------------------------------------------------------- stores

/// A store whose batch is all or nothing (as the sealed snapshot's is) and whose next write to a key
/// containing [failOn] fails once.
class AtomicStore extends MemoryChatStore {
  String? failOn;
  @override
  Future<void> write(String key, String value) {
    final pattern = failOn;
    if (pattern != null && key.contains(pattern)) {
      failOn = null;
      throw const FileSystemException('disk full');
    }
    return super.write(key, value);
  }

  @override
  Future<T> batch<T>(Future<T> Function() work) async {
    final before = Map<String, String>.of(values);
    try {
      return await work();
    } catch (_) {
      values
        ..clear()
        ..addAll(before);
      rethrow;
    }
  }
}
