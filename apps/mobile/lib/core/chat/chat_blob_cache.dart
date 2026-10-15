import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The name a cached blob is stored under: a digest of the conversation, the
/// blob id and the ciphertext hash the descriptor promises. A peer can write
/// any blob id into a descriptor, but cannot make one collide with a photo of
/// another conversation, nor with different bytes under the same id.
String blobCacheKey(
  String conversationId,
  String blobId,
  List<int> ctSha256,
) => sha256
    .convert(
      utf8.encode(
        'hiyall-blob-cache-v1\n$conversationId\n$blobId\n${base64Encode(ctSha256)}',
      ),
    )
    .toString();

final _keyShape = RegExp(r'^[0-9a-f]{64}$');

/// Verified ciphertext of chat photos, one file per [blobCacheKey], kept in the app's
/// private storage. Plaintext is never written: a file here is useless without
/// the key that only the message holds. The least recently used files are
/// evicted once the folder passes [maxBytes].
class ChatBlobCache {
  final Directory root;
  final int maxBytes;
  ChatBlobCache(this.root, {this.maxBytes = 200 * 1024 * 1024});

  bool _closed = false;

  /// After this nothing is written any more ([put] and [adopt] throw): the account that owns the cache is
  /// being wiped, and a download that finishes late must not put its file back.
  void close() => _closed = true;

  File _file(String key) {
    // Keys are digests; this is the check before one becomes part of a path.
    if (!_keyShape.hasMatch(key)) throw ArgumentError('not a cache key');
    return File('${root.path}/$key');
  }

  /// The cached ciphertext, or null. Reading marks the file as recently used.
  Future<Uint8List?> read(String key) async {
    final file = _file(key);
    try {
      final bytes = await file.readAsBytes();
      await file.setLastModified(DateTime.now());
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> has(String key) => _file(key).exists();

  /// Stores ciphertext the caller has already verified.
  Future<void> put(String key, Uint8List bytes) async {
    if (_closed) throw StateError('the photo cache is closed');
    await root.create(recursive: true);
    final file = _file(key);
    final temp = File('${file.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    await _evict();
  }

  /// Takes over a file already on disk (an upload's ciphertext) without copying.
  Future<void> adopt(String key, File source) async {
    if (_closed) throw StateError('the photo cache is closed');
    await root.create(recursive: true);
    final file = _file(key);
    try {
      await source.rename(file.path);
    } on FileSystemException {
      await source.copy(file.path);
      await source.delete();
    }
    await _evict();
  }

  Future<void> delete(String key) async {
    try {
      await _file(key).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  Future<void> deleteAll(Iterable<String> keys) async {
    for (final key in keys) {
      await delete(key);
    }
  }

  /// Removes everything: used on sign-out.
  Future<void> wipe() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // Best effort; a locked file is removed with the app's data.
    }
  }

  Future<int> size() async {
    var total = 0;
    if (!await root.exists()) return 0;
    await for (final e in root.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> _evict() async {
    final files = <(File, int, DateTime)>[];
    var total = 0;
    await for (final e in root.list()) {
      if (e is! File) continue;
      final stat = await e.stat();
      files.add((e, stat.size, stat.modified));
      total += stat.size;
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (file, size, _) in files) {
      if (total <= maxBytes) break;
      await file.delete();
      total -= size;
    }
  }
}
