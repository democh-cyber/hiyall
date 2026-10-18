import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'chat_api.dart';
import 'chat_attachment.dart';
import 'chat_av.dart' show BlobSpec;
import 'chat_blob_cache.dart';
import 'chat_blob_codec.dart';
import 'chat_blob_transport.dart';

enum MediaProblem {
  /// Expired, deleted or no longer for this account: retrying cannot help.
  unavailable,

  /// Offline or the service is busy: retrying may help.
  network,

  /// The bytes failed their hash or did not decrypt: this photo is damaged.
  corrupt,
  other,
}

class ChatMediaFailure implements Exception {
  final MediaProblem problem;
  const ChatMediaFailure(this.problem);
  @override
  String toString() => 'ChatMediaFailure(${problem.name})';
}

/// Fetches, verifies, caches and decrypts the blobs of received photos. The
/// order is fixed: the SHA-256 of the ciphertext is checked against the
/// descriptor before the bytes are cached or decrypted; only verified
/// ciphertext is written to disk; plaintext exists in memory only.
class ChatMedia {
  final ChatApi api;
  final ChatBlobTransport transport;
  final ChatBlobCodec codec;
  final ChatBlobCache cache;
  final int maxParallel;
  ChatMedia({
    required this.api,
    required this.transport,
    required this.codec,
    required this.cache,
    this.maxParallel = 3,
  });

  final _inflight = <String, _Fetch>{};
  final _waiting = <Completer<void>>[];
  var _active = 0;

  Future<void> _slot() async {
    if (_active < maxParallel) {
      _active++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }

  void _release() {
    if (_waiting.isEmpty) {
      _active--;
    } else {
      _waiting.removeAt(0).complete();
    }
  }

  /// The decrypted JPEG of one part of a photo. Concurrent calls for the same
  /// blob share one transfer. Throws [ChatMediaFailure].
  Future<Uint8List> plaintext(
    String conversationId,
    ChatAttachment att,
    BlobRole role, {
    void Function(double progress)? onProgress,
  }) {
    final part = att.part(role);
    final id = part.blobId;
    if (id == null) {
      return Future.error(const ChatMediaFailure(MediaProblem.other));
    }
    return plaintextBlob(
      conversationId,
      BlobSpec(
        blobId: id,
        role: role.name,
        salt: att.salt,
        mime: att.mime,
        key: att.key,
        chunk: att.chunk,
        plainLen: part.plainLen,
        ctSize: part.ctSize,
        ctSha256: part.ctSha256,
      ),
      onProgress: onProgress,
    );
  }

  /// The decrypted bytes of any blob (a photo part, a voice message, a video or its poster) described by
  /// [spec]: the same order for all of them (hash before anything else, verified ciphertext cached,
  /// plaintext in memory only). Throws [ChatMediaFailure].
  Future<Uint8List> plaintextBlob(
    String conversationId,
    BlobSpec spec, {
    void Function(double progress)? onProgress,
  }) {
    final running = _inflight[spec.blobId];
    if (running != null) {
      if (onProgress != null) running.listeners.add(onProgress);
      return running.future;
    }
    final fetch = _Fetch();
    if (onProgress != null) fetch.listeners.add(onProgress);
    _inflight[spec.blobId] = fetch;
    fetch.future = _fetch(conversationId, spec, fetch).whenComplete(() {
      _inflight.remove(spec.blobId);
    });
    return fetch.future;
  }

  Future<Uint8List> _fetch(
    String conversationId,
    BlobSpec spec,
    _Fetch fetch,
  ) async {
    final id = spec.blobId;
    Future<Uint8List> open(Uint8List ciphertext) => codec.decrypt(
      key: spec.key,
      role: spec.role,
      salt: spec.salt,
      conversationId: conversationId,
      mime: spec.mime,
      chunkSize: spec.chunk,
      plainLen: spec.plainLen,
      ctSha256: spec.ctSha256,
      ciphertext: ciphertext,
    );

    final key = blobCacheKey(conversationId, id, spec.ctSha256);
    final cached = await cache.read(key);
    if (cached != null) {
      if (_matches(cached, spec.ctSize, spec.ctSha256)) {
        // A file that verifies against its own descriptor is never deleted
        // because of what a message says: if it will not decrypt, the
        // descriptor is the problem, and the same bytes would come again.
        try {
          return await open(cached);
        } catch (_) {
          throw const ChatMediaFailure(MediaProblem.corrupt);
        }
      }
      // Damaged on disk: replaced from the network.
      await cache.delete(key);
    }
    await _slot();
    try {
      final Uint8List ciphertext;
      try {
        final link = await api.blobDownloadUrl(conversationId, id);
        if (link.sizeBytes != null && link.sizeBytes != spec.ctSize) {
          throw const ChatMediaFailure(MediaProblem.corrupt);
        }
        ciphertext = await transport.download(
          link.url,
          maxBytes: spec.ctSize,
          onProgress: (got, total) => fetch.report(total > 0 ? got / total : 0),
        );
      } on ChatMediaFailure {
        rethrow;
      } catch (e) {
        throw ChatMediaFailure(_classify(e));
      }
      // Hash first: nothing unverified is cached or decrypted.
      if (!_matches(ciphertext, spec.ctSize, spec.ctSha256)) {
        throw const ChatMediaFailure(MediaProblem.corrupt);
      }
      final Uint8List plain;
      try {
        plain = await open(ciphertext);
      } catch (_) {
        throw const ChatMediaFailure(MediaProblem.corrupt);
      }
      try {
        await cache.put(key, ciphertext);
      } catch (_) {
        // A full disk costs a later download, not the photo.
      }
      fetch.report(1);
      return plain;
    } finally {
      _release();
    }
  }

  static bool _matches(Uint8List ciphertext, int ctSize, Uint8List ctSha256) {
    if (ciphertext.length != ctSize) return false;
    final digest = sha256.convert(ciphertext).bytes;
    if (digest.length != ctSha256.length) return false;
    var diff = 0;
    for (var i = 0; i < digest.length; i++) {
      diff |= digest[i] ^ ctSha256[i];
    }
    return diff == 0;
  }

  static MediaProblem _classify(Object error) {
    if (error is ChatFailure) {
      if (error.status == 404 ||
          error.status == 410 ||
          error.code == 'BLOB_EXPIRED') {
        return MediaProblem.unavailable;
      }
      if (error.code == 'CORRUPT') return MediaProblem.corrupt;
      if (error.code == 'NETWORK' ||
          error.status == 429 ||
          error.status == 401 ||
          (error.status ?? 0) >= 500) {
        return MediaProblem.network;
      }
      // The signed link was refused (expired or already used): ask again.
      if (error.code == 'STORAGE_REFUSED') return MediaProblem.network;
      return MediaProblem.other;
    }
    if (error is DioException) return MediaProblem.network;
    return MediaProblem.other;
  }

  /// Forgets cached ciphertext of these entries (their message was deleted);
  /// see [blobCacheKey].
  Future<void> forget(Iterable<String> keys) => cache.deleteAll(keys);
}

class _Fetch {
  final listeners = <void Function(double)>[];
  late Future<Uint8List> future;
  void report(double value) {
    for (final l in listeners) {
      l(value);
    }
  }
}
