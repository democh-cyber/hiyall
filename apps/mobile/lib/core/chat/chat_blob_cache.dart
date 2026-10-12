import 'dart:io';
import 'dart:typed_data';

import 'chat_attachment.dart';

/// Verified ciphertext of chat photos, one file per blob id, kept in the app's
/// private storage. Plaintext is never written: a file here is useless without
/// the key that only the message holds. The least recently used files are
/// evicted once the folder passes [maxBytes].
class ChatBlobCache {
  final Directory root;
  final int maxBytes;
  ChatBlobCache(this.root, {this.maxBytes = 200 * 1024 * 1024});

  File _file(String blobId) {
    // Ids come from validated descriptors; this is the second check before one
    // becomes part of a path.
    if (!isCanonicalUuid(blobId)) throw ArgumentError('not a blob id');
    return File('${root.path}/$blobId');
  }

  /// The cached ciphertext, or null. Reading marks the file as recently used.
  Future<Uint8List?> read(String blobId) async {
    final file = _file(blobId);
    try {
      final bytes = await file.readAsBytes();
      await file.setLastModified(DateTime.now());
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> has(String blobId) => _file(blobId).exists();

  /// Stores ciphertext the caller has already verified.
  Future<void> put(String blobId, Uint8List bytes) async {
    await root.create(recursive: true);
    final file = _file(blobId);
    final temp = File('${file.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    await _evict();
  }

  /// Takes over a file already on disk (an upload's ciphertext) without copying.
  Future<void> adopt(String blobId, File source) async {
    await root.create(recursive: true);
    final file = _file(blobId);
    try {
      await source.rename(file.path);
    } on FileSystemException {
      await source.copy(file.path);
      await source.delete();
    }
    await _evict();
  }

  Future<void> delete(String blobId) async {
    try {
      await _file(blobId).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  Future<void> deleteAll(Iterable<String> blobIds) async {
    for (final id in blobIds) {
      await delete(id);
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
