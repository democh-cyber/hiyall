import 'dart:convert';

import 'chat_groups.dart';
import 'chat_store.dart';

/// What this phone remembers about one group, kept per account under `hiyall.chat.<userId>.groups` in the same
/// sealed store as the history (so it is wiped with the rest of the account's chat data, see
/// `ChatLocalData.wipeAccount`). See docs/mobile/19-group-chat.md, "Membership changes".
class GroupLocal {
  /// How many notice ids and handled control message ids are remembered per group.
  static const rememberMax = 400;

  final String ownerId, name;
  final DateTime createdAt;

  /// The active members the relay listed last (the person's own account included).
  final List<GroupMember> roster;

  /// Everyone who was ever seen as an active member, by id, so an old message and a notice still show a name
  /// after that person left.
  final Map<String, GroupMember> directory;

  /// Removal marks: people this phone was told left, were removed or deleted their account, and the relay's
  /// time of it. Nothing is sealed for a marked person, whatever the relay lists.
  final Map<String, DateTime> marks;

  /// The people this phone has accounted for: everyone the relay listed when it first saw the group (a creator
  /// only accounts for themself), plus everyone whose authenticated `join` it received. A listed member who is
  /// not here (and not marked) is "not confirmed".
  final Set<String> accounted;

  /// Notice ids already shown, oldest first, so an event and the control message that carried it never make two
  /// notices.
  final List<String> shown;

  /// Control message ids whose effects were applied, oldest first (a replay changes nothing).
  final List<String> done;

  /// This account was removed, left, or the group closed: nothing more is sent here.
  final bool readOnly;

  /// When the person deleted this group from their list on this phone; only used for a group the relay no
  /// longer lists (a read-only one), so it can still be found in the Deleted chats and restored.
  final DateTime? hiddenAt;
  const GroupLocal({
    required this.ownerId,
    required this.name,
    required this.createdAt,
    this.roster = const [],
    this.directory = const {},
    this.marks = const {},
    this.accounted = const {},
    this.shown = const [],
    this.done = const [],
    this.readOnly = false,
    this.hiddenAt,
  });

  GroupLocal copyWith({
    String? ownerId,
    String? name,
    DateTime? createdAt,
    List<GroupMember>? roster,
    Map<String, GroupMember>? directory,
    Map<String, DateTime>? marks,
    Set<String>? accounted,
    List<String>? shown,
    List<String>? done,
    bool? readOnly,
    DateTime? hiddenAt,
    bool clearHidden = false,
  }) => GroupLocal(
    ownerId: ownerId ?? this.ownerId,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    roster: roster ?? this.roster,
    directory: directory ?? this.directory,
    marks: marks ?? this.marks,
    accounted: accounted ?? this.accounted,
    shown: shown ?? this.shown,
    done: done ?? this.done,
    readOnly: readOnly ?? this.readOnly,
    hiddenAt: clearHidden ? null : hiddenAt ?? this.hiddenAt,
  );

  static List<String> _remember(List<String> list, String id) {
    if (list.contains(id)) return list;
    final next = [...list, id];
    return next.length > rememberMax
        ? next.sublist(next.length - rememberMax)
        : next;
  }

  GroupLocal withShown(String noticeId) =>
      copyWith(shown: _remember(shown, noticeId));
  GroupLocal withDone(String messageId) =>
      copyWith(done: _remember(done, messageId));

  /// The name to show for [userId]: from the directory, else null.
  String? nameOf(String userId) => directory[userId]?.name;

  Map<String, dynamic> toJson() => {
    'o': ownerId,
    'n': name,
    'c': createdAt.toUtc().toIso8601String(),
    'r': [for (final m in roster) m.toJson()],
    'd': {for (final e in directory.entries) e.key: e.value.toJson()},
    if (marks.isNotEmpty)
      'm': {
        for (final e in marks.entries) e.key: e.value.toUtc().toIso8601String(),
      },
    'a': accounted.toList()..sort(),
    's': shown,
    if (done.isNotEmpty) 'x': done,
    if (readOnly) 'ro': true,
    if (hiddenAt != null) 'h': hiddenAt!.toUtc().toIso8601String(),
  };

  /// Reads one stored group; null when it is not one (it is then forgotten and seen afresh at the next
  /// refresh).
  static GroupLocal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final owner = raw['o'], created = DateTime.tryParse('${raw['c']}');
    if (owner is! String || created == null) return null;
    final directory = <String, GroupMember>{};
    final d = raw['d'];
    if (d is Map) {
      for (final e in d.entries) {
        final m = GroupMember.parse(e.value);
        if (e.key is String && m != null) directory[e.key as String] = m;
      }
    }
    final marks = <String, DateTime>{};
    final m = raw['m'];
    if (m is Map) {
      for (final e in m.entries) {
        final at = DateTime.tryParse('${e.value}');
        if (e.key is String && at != null) marks[e.key as String] = at;
      }
    }
    List<String> strings(Object? v) => [
      if (v is List)
        for (final s in v)
          if (s is String) s,
    ];
    return GroupLocal(
      ownerId: owner,
      name: raw['n'] as String? ?? '',
      createdAt: created,
      roster: [
        if (raw['r'] is List)
          for (final x in raw['r'] as List) ?GroupMember.parse(x),
      ],
      directory: directory,
      marks: marks,
      accounted: strings(raw['a']).toSet(),
      shown: strings(raw['s']),
      done: strings(raw['x']),
      readOnly: raw['ro'] == true,
      hiddenAt: DateTime.tryParse('${raw['h']}'),
    );
  }
}

/// All of an account's [GroupLocal]s in one store entry. Reads are synchronous once [load] has run (the engine
/// loads it when it starts). A write changes the memory and the entry together; when it fails, memory is put
/// back. When a write that was part of a bigger commit is rolled back with that commit, [reload] puts memory
/// back to what the store holds.
class GroupStore {
  final ChatStore store;
  final String key;
  GroupStore(this.store, this.key);

  Map<String, GroupLocal> _groups = {};
  String? _stored;

  /// Reads the entry. Anything in it that cannot be read is skipped.
  Future<void> load() async {
    final raw = await store.read(key);
    final out = <String, GroupLocal>{};
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          for (final e in json.entries) {
            final g = GroupLocal.fromJson(e.value);
            if (e.key is String && g != null) out[e.key as String] = g;
          }
        }
      } catch (_) {
        // Unreadable: groups are seen afresh at the next refresh.
      }
    }
    _groups = out;
    _stored = raw;
  }

  /// [load] that never throws (after a failed commit the old memory simply stays).
  Future<void> reloadQuietly() async {
    try {
      await load();
    } catch (_) {}
  }

  GroupLocal? operator [](String id) => _groups[id];
  bool has(String id) => _groups.containsKey(id);
  Iterable<String> get ids => _groups.keys;

  String _encode(Map<String, GroupLocal> groups) =>
      jsonEncode({for (final e in groups.entries) e.key: e.value.toJson()});

  Future<void> put(String id, GroupLocal group) => putAll({id: group});

  Future<void> putAll(Map<String, GroupLocal> changes) =>
      _write({..._groups, ...changes});

  /// Forgets these groups.
  Future<void> remove(Iterable<String> ids) {
    final gone = ids.toSet();
    if (!_groups.keys.any(gone.contains)) return Future.value();
    return _write({
      for (final e in _groups.entries)
        if (!gone.contains(e.key)) e.key: e.value,
    });
  }

  Future<void> _write(Map<String, GroupLocal> next) async {
    final encoded = next.isEmpty ? null : _encode(next);
    if (encoded == _stored) {
      _groups = next;
      return;
    }
    final before = _groups, beforeStored = _stored;
    _groups = next;
    _stored = encoded;
    try {
      if (encoded == null) {
        await store.delete(key);
      } else {
        await store.write(key, encoded);
      }
    } catch (_) {
      if (identical(_groups, next)) {
        _groups = before;
        _stored = beforeStored;
      }
      rethrow;
    }
  }
}
