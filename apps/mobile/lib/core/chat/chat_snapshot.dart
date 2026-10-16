import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../src/rust/api/seal.dart' as native;
import 'chat_store.dart';

// One encrypted snapshot file per account (docs/security/13, "Atomic encrypted
// storage"). Everything the chat engine keeps except three small secrets
// (below) lives in it: Olm account and sessions, pinned keys, history, pending
// reactions, the outbox index. A commit writes a temporary file, flushes it to
// disk, then renames it over the old snapshot, so a crash leaves the old
// snapshot or the new one, never a mix.

/// The disk under the snapshot. The app uses [DirectorySnapshotFiles]; crash
/// tests inject one that fails at a chosen step.
abstract class SnapshotFiles {
  /// The file's bytes, or null if there is none.
  Future<Uint8List?> read(String name);

  /// Creates or replaces [name] with [bytes] and forces them to disk before
  /// returning.
  Future<void> writeSynced(String name, Uint8List bytes);

  /// Moves [from] over [to] in one step (replacing it); throws if [from] is
  /// missing.
  Future<void> rename(String from, String to);

  /// Removes [name]; a missing file is fine.
  Future<void> delete(String name);
}

class DirectorySnapshotFiles implements SnapshotFiles {
  final Directory dir;
  const DirectorySnapshotFiles(this.dir);

  File _file(String name) => File('${dir.path}/$name');

  @override
  Future<Uint8List?> read(String name) async {
    try {
      return await _file(name).readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> writeSynced(String name, Uint8List bytes) async {
    await dir.create(recursive: true);
    final file = await _file(name).open(mode: FileMode.write);
    try {
      await file.writeFrom(bytes);
      await file.flush(); // fsync
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    await _file(from).rename(_file(to).path);
  }

  @override
  Future<void> delete(String name) async {
    try {
      await _file(name).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }
}

/// Authenticated encryption of a snapshot. [open] throws if the bytes, the key
/// or [aad] differ from what [seal] was given.
abstract class SnapshotSealer {
  Future<Uint8List> seal(Uint8List plain, Uint8List aad);
  Future<Uint8List> open(Uint8List sealed, Uint8List aad);
}

/// XChaCha20-Poly1305 in the Rust core (`api/seal.rs`).
class RustSnapshotSealer implements SnapshotSealer {
  final List<int> key;
  const RustSnapshotSealer(this.key);
  @override
  Future<Uint8List> seal(Uint8List plain, Uint8List aad) =>
      native.sealState(key: key, aad: aad, plaintext: plain);
  @override
  Future<Uint8List> open(Uint8List sealed, Uint8List aad) =>
      native.openState(key: key, aad: aad, sealed: sealed);
}

/// What [SnapshotChatStore.open] found.
class SnapshotOpenInfo {
  /// The generation that was loaded (0 when there was nothing).
  final int generation;

  /// Which file it came from, or null when there was none that opened.
  final String? loadedFrom;

  /// Entries moved over from the old per-key secure storage.
  final int migrated;

  /// Snapshot files existed but none could be opened (the key is gone, or the
  /// files are damaged): the account starts empty and registers a new device.
  final bool lost;

  /// The snapshot that opened was the previous generation (`.snap.prev`): the current file and any newer
  /// one were missing or damaged, so this is an older state than the one last committed. The saved ratchets
  /// may be behind what peers have already seen, so the engine treats it like [lost] and starts a new
  /// identity (audit CHAT-N8).
  final bool rolledBack;
  const SnapshotOpenInfo({
    required this.generation,
    required this.loadedFrom,
    required this.migrated,
    required this.lost,
    this.rolledBack = false,
  });

  /// The engine must not carry on with the saved identity.
  bool get identityUntrusted => lost || rolledBack;
}

/// A [ChatStore] for one account whose entries live in one sealed file.
///
/// Three small values stay in the platform keystore beside it: the snapshot
/// key, the Olm pickle key and the device id. Sign-out and reinstall handling
/// read them there without opening the snapshot, and the keys never sit next
/// to what they protect. Keys of other accounts, the owner marker and the
/// pending-revoke note pass straight through to [secure].
///
/// Writes are applied in memory at once and committed together: every write
/// that arrives while a commit runs joins the next one ("group commit"), and a
/// write returns when its commit is on disk. [batch] makes everything its work
/// writes one commit; it either lands whole or not at all. A failed commit
/// puts the entries it changed back as they were.
class SnapshotChatStore implements ChatStore {
  static const magic = [0x48, 0x59, 0x43, 0x53]; // "HYCS"
  static const formatVersion = 1;
  static const headerLength = 13;

  /// Entry names (after the `hiyall.chat.<userId>.` prefix) that stay in the
  /// platform keystore.
  static const keystoreNames = {'pickleKey', 'deviceId', 'snapKey'};

  final String userId;
  final ChatStore secure;
  final SnapshotFiles files;
  final SnapshotSealer sealer;

  /// What [open] found.
  late final SnapshotOpenInfo info;

  final Map<String, String> _map;
  final _encoded = <String, Uint8List>{};
  int _generation;
  bool _hasSnapshot;

  SnapshotChatStore._(
    this.userId,
    this.secure,
    this.files,
    this.sealer,
    this._map,
    this._generation,
    this._hasSnapshot,
  );

  String get _prefix => 'hiyall.chat.$userId.';
  String get _base => _fileSafe(userId);
  String get snapshotName => '$_base.snap';
  String get tempName => '$_base.snap.tmp';
  String get previousName => '$_base.snap.prev';

  static String _fileSafe(String user) =>
      user.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Opens [userId]'s snapshot: the newest generation that decrypts, among the
  /// snapshot, the temporary file a crash may have left and the previous
  /// snapshot. Entries written by earlier builds directly into [secure] are
  /// moved into the snapshot first (read, write the snapshot, delete the old).
  ///
  /// [newKey] makes the 32-byte snapshot key; [sealerFor] builds the cipher.
  /// Both default to the Rust core.
  static Future<SnapshotChatStore> open({
    required ChatStore secure,
    required String userId,
    required SnapshotFiles files,
    List<int> Function()? newKey,
    SnapshotSealer Function(List<int> key)? sealerFor,
  }) async {
    final prefix = 'hiyall.chat.$userId.';
    final keyName = '${prefix}snapKey';
    final base = _fileSafe(userId);
    final names = ['$base.snap', '$base.snap.tmp', '$base.snap.prev'];
    // A keystore that cannot be read is an error to try again, never a missing key: a key made now would not
    // open the snapshot that is already on disk, and the account would start empty (audit CHAT-N4).
    final String? saved;
    try {
      saved = await secure.read(keyName);
    } on ChatStorageUnavailable {
      rethrow;
    } catch (error) {
      throw ChatStorageUnavailable(error);
    }
    List<int>? decoded;
    if (saved != null) {
      try {
        decoded = base64Decode(saved);
      } on FormatException {
        // Bytes were read and are not a key (a damaged entry): nothing opens with it, so it is replaced and
        // the files it protected count as lost, like any lost key.
      }
    }
    final key = decoded ?? (newKey ?? native.generateSealKey)();
    if (decoded == null) await secure.write(keyName, base64Encode(key));
    final sealer = (sealerFor ?? RustSnapshotSealer.new)(key);

    // The newest generation that authenticates wins.
    var generation = 0;
    String? loadedFrom;
    Map<String, String>? entries;
    var existed = false;
    for (final name in names) {
      final bytes = await files.read(name);
      if (bytes == null) continue;
      existed = true;
      final parsed = await _decode(bytes, sealer, userId);
      if (parsed != null && (entries == null || parsed.$1 > generation)) {
        generation = parsed.$1;
        entries = parsed.$2;
        loadedFrom = name;
      }
    }
    // Files that nothing opens (the key was lost) are of no use to anyone.
    if (existed && entries == null) {
      for (final name in names) {
        await files.delete(name);
      }
    }

    final store = SnapshotChatStore._(
      userId,
      secure,
      files,
      sealer,
      entries ?? <String, String>{},
      generation,
      entries != null,
    );
    final legacy = [
      for (final k in await secure.keys())
        if (k.startsWith(prefix) &&
            !keystoreNames.contains(k.substring(prefix.length)))
          k,
    ];
    var migrated = 0;
    if (legacy.isNotEmpty) {
      if (entries == null) {
        // First run on this format: read the old entries, write the snapshot,
        // and only then delete them. A crash before the write leaves the old
        // entries; after it, the snapshot wins and the rest are deleted below.
        for (final k in legacy) {
          final value = await secure.read(k);
          if (value != null) {
            store._map[k] = value;
            migrated++;
          }
        }
        await store._persist();
        loadedFrom = store.snapshotName;
      }
      for (final k in legacy) {
        await secure.delete(k);
      }
    }
    store.info = SnapshotOpenInfo(
      generation: store._generation,
      loadedFrom: loadedFrom,
      migrated: migrated,
      lost: existed && entries == null && migrated == 0,
      rolledBack: loadedFrom == store.previousName,
    );
    return store;
  }

  bool _ours(String key) =>
      key.startsWith(_prefix) &&
      !keystoreNames.contains(key.substring(_prefix.length));

  // ------------------------------------------------------------- reads

  @override
  Future<String?> read(String key) async =>
      _ours(key) ? _map[key] : secure.read(key);

  @override
  Future<List<String>> keys() async => [..._map.keys, ...await secure.keys()];

  /// The generation on disk (tests and diagnostics).
  int get generation => _generation;

  // ------------------------------------------------------------ writes

  static final Object _zoneKey = Object();
  _Group? _activeBatch;
  Future<void> _batchTail = Future.value();
  _Group? _scheduled;
  Future<void> _running = Future.value();

  _Group? get _inBatch {
    final g = Zone.current[_zoneKey];
    return g is _Group && identical(g, _activeBatch) ? g : null;
  }

  @override
  Future<void> write(String key, String value) => _set(key, value);

  @override
  Future<void> delete(String key) => _set(key, null);

  Future<void> _set(String key, String? value) async {
    if (!_ours(key)) {
      return value == null ? secure.delete(key) : secure.write(key, value);
    }
    final batch = _inBatch;
    if (batch != null) {
      _put(key, value, batch);
      return;
    }
    // Writes from outside wait for a running batch, so a batch that fails can
    // put everything back without taking anyone else's write with it.
    while (_activeBatch != null) {
      await _batchTail;
    }
    if (_map[key] == value) return;
    final group = _join();
    _put(key, value, group);
    await group.done.future;
  }

  void _put(String key, String? value, _Group group) {
    final before = _map[key];
    if (before == value) return;
    group.ops.add(_Op(key, before, value));
    _encoded.remove(key);
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  /// The commit that has not started yet, or a new one.
  _Group _join() {
    final open = _scheduled;
    if (open != null) return open;
    final group = _scheduled = _Group();
    _running = _running.then((_) => _run(group));
    return group;
  }

  Future<void> _run(_Group group) async {
    if (identical(_scheduled, group)) _scheduled = null;
    try {
      await _persist();
      group.done.complete();
    } catch (error, stack) {
      _revert(group);
      group.done.completeError(error, stack);
    }
  }

  void _revert(_Group group) {
    if (group.reverted) return;
    group.reverted = true;
    for (final op in group.ops.reversed) {
      // Only if nothing newer replaced it meanwhile.
      if (_map[op.key] != op.after) continue;
      _encoded.remove(op.key);
      if (op.before == null) {
        _map.remove(op.key);
      } else {
        _map[op.key] = op.before!;
      }
    }
  }

  /// Runs [work] and commits everything it wrote as one snapshot, or nothing
  /// if it throws or the commit fails. Writes from other callers wait until it
  /// is done, so it cannot be interleaved; only [work] and what it awaits may
  /// write to this store inside it. Nested calls just run [work].
  @override
  Future<T> batch<T>(Future<T> Function() work) async {
    if (_inBatch != null) return work();
    final before = _batchTail;
    final mine = Completer<void>();
    _batchTail = mine.future;
    await before;
    final group = _Group();
    _activeBatch = group;
    try {
      final result = await Zone.current
          .fork(zoneValues: {_zoneKey: group})
          .run(work);
      if (group.ops.isNotEmpty) {
        _running = _running.then((_) => _run(group));
        await group.done.future;
      }
      return result;
    } catch (_) {
      _revert(group);
      rethrow;
    } finally {
      _activeBatch = null;
      mine.complete();
    }
  }

  // ------------------------------------------------------------ commit

  /// Seals the current entries as the next generation and puts them on disk.
  Future<void> _persist() async {
    final snapshot = Map<String, String>.of(_map);
    final next = _generation + 1;
    final body = _encode(snapshot);
    final sealed = await sealer.seal(body, _aad(userId, next));
    final out = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(formatVersion)
      ..add(_u64(next))
      ..add(sealed);
    try {
      await files.writeSynced(tempName, out.takeBytes());
      if (_hasSnapshot) {
        // The previous snapshot is a spare for a damaged main file; if it
        // cannot be kept (it may be missing after an earlier failure) the
        // commit still goes ahead.
        try {
          await files.rename(snapshotName, previousName);
        } catch (_) {}
      }
      await files.rename(tempName, snapshotName);
    } catch (_) {
      // Not committed as far as the caller is concerned: do not leave a valid
      // newer file behind for a later open to pick (best effort; a crash that
      // never gets here leaves the new snapshot, which is as good).
      try {
        await files.delete(tempName);
      } catch (_) {}
      rethrow;
    }
    _generation = next;
    _hasSnapshot = true;
  }

  Uint8List _encode(Map<String, String> entries) {
    final out = BytesBuilder(copy: false)..add(_u32(entries.length));
    for (final e in entries.entries) {
      final key = utf8.encode(e.key);
      final value = _encoded[e.key] ??= Uint8List.fromList(
        utf8.encode(e.value),
      );
      out
        ..add(_u32(key.length))
        ..add(key)
        ..add(_u32(value.length))
        ..add(value);
    }
    return out.takeBytes();
  }

  static Uint8List _u32(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v);
  static Uint8List _u64(int v) =>
      Uint8List(8)..buffer.asByteData().setUint64(0, v);

  static Uint8List _aad(String userId, int generation) => Uint8List.fromList([
    ...utf8.encode('hiyall-chat-snapshot-v1|$userId|'),
    ..._u64(generation),
  ]);

  /// (generation, entries) of one file, or null if it is not a snapshot this
  /// key can open.
  static Future<(int, Map<String, String>)?> _decode(
    Uint8List bytes,
    SnapshotSealer sealer,
    String userId,
  ) async {
    try {
      if (bytes.length <= headerLength) return null;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return null;
      }
      if (bytes[4] != formatVersion) return null;
      final data = ByteData.sublistView(bytes);
      final generation = data.getUint64(5);
      final plain = await sealer.open(
        Uint8List.sublistView(bytes, headerLength),
        _aad(userId, generation),
      );
      final view = ByteData.sublistView(plain);
      var at = 0;
      int u32() {
        final v = view.getUint32(at);
        at += 4;
        return v;
      }

      String text() {
        final n = u32();
        if (n < 0 || at + n > plain.length) throw const FormatException();
        final s = utf8.decode(Uint8List.sublistView(plain, at, at + n));
        at += n;
        return s;
      }

      final count = u32();
      final entries = <String, String>{};
      for (var i = 0; i < count; i++) {
        final k = text();
        entries[k] = text();
      }
      if (at != plain.length) return null;
      return (generation, entries);
    } catch (_) {
      return null;
    }
  }
}

class _Op {
  final String key;
  final String? before, after;
  const _Op(this.key, this.before, this.after);
}

class _Group {
  final ops = <_Op>[];
  final done = Completer<void>();
  bool reverted = false;
}
