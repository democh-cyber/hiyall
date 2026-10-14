import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'chat_api.dart';
import 'chat_attachment.dart';
import 'chat_blob_cache.dart';
import 'chat_blob_codec.dart';
import 'chat_blob_transport.dart';
import 'chat_engine.dart';
import 'chat_history.dart';
import 'chat_reactions.dart';
import 'chat_store.dart';
import 'chat_text.dart';

/// Sends the message through the end-to-end encrypted path (the engine's
/// Olm envelopes) and returns the relay's timestamp. Retrying the same
/// [messageId] is idempotent on the relay.
typedef PhotoDeliver = Future<DateTime?> Function(
  String conversationId,
  String peerId,
  String messageId,
  Map<String, dynamic> payload,
  List<String> blobIds,
);

/// Upload progress of one outgoing photo, from 0 to 1.
class TransferProgress {
  double value = 0;
  final _changes = StreamController<double>.broadcast();
  Stream<double> get changes => _changes.stream;
  void update(double next) {
    value = next.clamp(0, 1).toDouble();
    if (!_changes.isClosed) _changes.add(value);
  }

  void close() => _changes.close();
}

enum PartStage { ready, uploaded, completed }

class OutboxPart {
  final String file;
  PartStage stage;
  String? blobId;
  OutboxPart(this.file, {this.stage = PartStage.ready, this.blobId});
  Map<String, dynamic> toJson() => {
    'file': file,
    'stage': stage.index,
    'blob': ?blobId,
  };
  factory OutboxPart.fromJson(Map<String, dynamic> j) => OutboxPart(
    j['file'] as String,
    stage: PartStage.values[j['stage'] as int],
    blobId: j['blob'] as String?,
  );
}

/// One photo on its way out. Everything needed to resume lives here and on
/// disk: the key, the ids and each blob's progress, plus the ciphertext
/// files (by name relative to the outbox folder: the app's data folder moves
/// between installs).
class OutboxEntry {
  final String messageId, conversationId, peerId;
  final DateTime sentAt;
  final ChatAttachment attachment;
  final OutboxPart full, thumb;

  /// The message this photo answers, quoted in its payload (null for none).
  final ChatReply? reply;
  OutboxEntry({
    required this.messageId,
    required this.conversationId,
    required this.peerId,
    required this.sentAt,
    required this.attachment,
    required this.full,
    required this.thumb,
    this.reply,
  });

  String get text =>
      attachment.caption.isEmpty ? photoFallbackText : attachment.caption;

  OutboxPart part(BlobRole role) => role == BlobRole.full ? full : thumb;

  Map<String, dynamic> toJson() => {
    'id': messageId,
    'conv': conversationId,
    'peer': peerId,
    'at': sentAt.toIso8601String(),
    'att': attachment.toLocalJson(),
    'full': full.toJson(),
    'thumb': thumb.toJson(),
    if (reply != null) 're': reply!.toJson(),
  };
  factory OutboxEntry.fromJson(Map<String, dynamic> j) => OutboxEntry(
    messageId: j['id'] as String,
    conversationId: j['conv'] as String,
    peerId: j['peer'] as String,
    sentAt: DateTime.parse(j['at'] as String),
    attachment: ChatAttachment.fromLocal(j['att']),
    full: OutboxPart.fromJson(Map<String, dynamic>.from(j['full'] as Map)),
    thumb: OutboxPart.fromJson(Map<String, dynamic>.from(j['thumb'] as Map)),
    reply: ChatReply.parse(j['re']),
  );
}

/// Sends photos: prepare, encrypt, upload, complete, then the message. Every
/// step is saved before the next, so a retry resumes with the same message id
/// and the same blobs instead of duplicating either. Uploads run outside the
/// engine's Olm lock; only the final delivery takes it.
class PhotoOutbox {
  final String userId;
  final ChatApi api;
  final ChatBlobTransport transport;
  final ChatBlobCodec codec;
  final ChatStore store;
  final ChatHistory history;
  final ChatBlobCache cache;
  final Directory dir;
  final PhotoDeliver deliver;
  final String storeKey;
  final Random _random;
  PhotoOutbox({
    required this.userId,
    required this.api,
    required this.transport,
    required this.codec,
    required this.store,
    required this.history,
    required this.cache,
    required this.dir,
    required this.deliver,
    required this.storeKey,
    Random? random,
  }) : _random = random ?? Random.secure();

  final _entries = <String, OutboxEntry>{};
  final _running = <String, CancelToken>{};
  final _progress = <String, TransferProgress>{};
  final _thumbs = <String, Uint8List>{};
  Future<void>? _loaded;
  Future<void> _saving = Future.value();

  Future<void> load() => _loaded ??= () async {
    final raw = await store.read(storeKey);
    if (raw == null) return;
    for (final item in jsonDecode(raw) as List) {
      try {
        final e = OutboxEntry.fromJson(Map<String, dynamic>.from(item as Map));
        _entries[e.messageId] = e;
      } catch (_) {
        // An unreadable entry is dropped rather than blocking the rest.
      }
    }
  }();

  Future<void> _save() {
    final snapshot = jsonEncode([for (final e in _entries.values) e.toJson()]);
    return _saving = _saving.then(
      (_) => store.write(storeKey, snapshot),
      onError: (_) => store.write(storeKey, snapshot),
    );
  }

  bool _disposed = false;

  /// Stops every upload and all further writes. What was in flight stays
  /// saved as it was; the next session shows it as failed, ready to retry.
  void dispose() {
    _disposed = true;
    for (final t in _running.values) {
      t.cancel();
    }
  }

  /// Entries still waiting to be sent (a failed or interrupted photo).
  List<OutboxEntry> get pending => List.unmodifiable(_entries.values);
  bool isRunning(String messageId) => _running.containsKey(messageId);
  TransferProgress? progress(String messageId) => _progress[messageId];

  /// The thumbnail of a photo sent in this session, so it shows at once.
  Uint8List? localThumb(String messageId) => _thumbs[messageId];

  Directory _folder(String messageId) => Directory('${dir.path}/$messageId');

  /// Prepares and encrypts [input], saves it, shows it as sending and starts
  /// the upload. Throws [ChatFailure] before anything is saved if the photo
  /// cannot be sent (unreadable, or its ciphertext is over the server's caps).
  Future<ChatMessage> enqueue(
    String conversationId,
    String peerId,
    Uint8List input, {
    String caption = '',
    ChatMessage? replyTo,
  }) async {
    await load();
    if (input.length > maxPhotoInput) {
      throw const ChatFailure(
        'PHOTO_TOO_LARGE',
        'That photo is too large to send.',
      );
    }
    final PreparedPhoto photo;
    try {
      photo = await codec.prepare(input);
    } catch (_) {
      throw const ChatFailure(
        'PHOTO_UNREADABLE',
        'That photo couldn’t be prepared. Try another one.',
      );
    }
    final key = codec.generateKey(), salt = newUuid4(_random);
    final messageId = newUuid4(_random);
    Future<SealedPart> seal(BlobRole role, Uint8List plain) => codec.encrypt(
      key: key,
      role: role.name,
      salt: salt,
      conversationId: conversationId,
      mime: attachmentMime,
      chunkSize: attachmentChunk,
      plaintext: plain,
    );
    final thumb = await seal(BlobRole.thumb, photo.thumb);
    final full = await seal(BlobRole.full, photo.full);
    // The padded ciphertext can be a little larger than the JPEG, so the
    // server's caps are checked on what would actually be uploaded.
    if (full.ciphertext.length > maxFullCiphertext ||
        thumb.ciphertext.length > maxThumbCiphertext) {
      throw const ChatFailure(
        'PHOTO_TOO_LARGE',
        'That photo is too large to send. Try a smaller one.',
      );
    }
    final attachment = ChatAttachment(
      key: key,
      salt: salt,
      mime: attachmentMime,
      chunk: attachmentChunk,
      full: BlobPart(
        blobId: null,
        w: photo.fullW,
        h: photo.fullH,
        plainLen: full.plainLen,
        ctSize: full.ciphertext.length,
        ctSha256: full.ctSha256,
      ),
      thumb: BlobPart(
        blobId: null,
        w: photo.thumbW,
        h: photo.thumbH,
        plainLen: thumb.plainLen,
        ctSize: thumb.ciphertext.length,
        ctSha256: thumb.ctSha256,
      ),
      preview: photo.preview,
      caption: sanitizeText(caption).trim(),
    );
    final folder = _folder(messageId);
    await folder.create(recursive: true);
    await File('${folder.path}/full.bin')
        .writeAsBytes(full.ciphertext, flush: true);
    await File('${folder.path}/thumb.bin')
        .writeAsBytes(thumb.ciphertext, flush: true);
    final entry = OutboxEntry(
      messageId: messageId,
      conversationId: conversationId,
      peerId: peerId,
      sentAt: DateTime.now().toUtc(),
      attachment: attachment,
      full: OutboxPart('$messageId/full.bin'),
      thumb: OutboxPart('$messageId/thumb.bin'),
      reply: replyTo == null ? null : replyOf(replyTo, userId),
    );
    _entries[messageId] = entry;
    await _save();
    _thumbs[messageId] = photo.thumb;
    while (_thumbs.length > 16) {
      _thumbs.remove(_thumbs.keys.first);
    }
    final message = ChatMessage(
      messageId: messageId,
      senderId: userId,
      text: entry.text,
      sentAt: entry.sentAt,
      mine: true,
      attachment: attachment,
      status: SendStatus.sending,
      reply: entry.reply,
    );
    await history.append(conversationId, message);
    _start(entry);
    return message;
  }

  /// Resumes a failed photo from the step it stopped at.
  Future<void> retry(String conversationId, String messageId) async {
    await load();
    final entry = _entries[messageId];
    if (entry == null) {
      throw const ChatFailure(
        'LOCAL_DATA_LOST',
        'This photo can’t be sent again. Delete it and choose it again.',
      );
    }
    if (_running.containsKey(messageId)) return;
    await _mark(entry, SendStatus.sending);
    _start(entry);
  }

  final _runs = <String, Future<void>>{};
  void _start(OutboxEntry entry) => _runs[entry.messageId] = _drive(entry);

  /// Completes when the upload of this message is not running (tests).
  Future<void> settled(String messageId) => _runs[messageId] ?? Future.value();

  /// Stops an upload in flight; the message stays as failed, ready to retry.
  void cancel(String messageId) => _running[messageId]?.cancel();

  /// Removes a photo that never went out: its message, files and any blob
  /// already uploaded.
  Future<void> discard(String conversationId, String messageId) async {
    await load();
    _running[messageId]?.cancel();
    final entry = _entries.remove(messageId);
    _progress.remove(messageId)?.close();
    _thumbs.remove(messageId);
    if (entry != null) {
      await _save();
      for (final p in [entry.full, entry.thumb]) {
        final id = p.blobId;
        if (id != null) unawaited(_quietDelete(id));
      }
      await _clean(messageId);
    }
    await history.remove(conversationId, messageId);
  }

  Future<void> _quietDelete(String blobId) async {
    try {
      await api.deleteBlob(blobId);
    } catch (_) {
      // It expires within the hour anyway.
    }
  }

  Future<void> _clean(String messageId) async {
    try {
      final folder = _folder(messageId);
      if (await folder.exists()) await folder.delete(recursive: true);
    } on FileSystemException {
      // Removed with the app's data at the latest.
    }
  }

  /// Sign-out: nothing of an unsent photo stays on the device.
  Future<void> wipe() async {
    for (final t in _running.values) {
      t.cancel();
    }
    _entries.clear();
    for (final p in _progress.values) {
      p.close();
    }
    _progress.clear();
    _thumbs.clear();
    await store.delete(storeKey);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }

  Future<void> _mark(
    OutboxEntry e,
    SendStatus status, [
    String? failure,
  ]) async {
    final current = (await history.read(e.conversationId))
        .where((m) => m.messageId == e.messageId)
        .firstOrNull;
    if (current == null) return;
    await history.replace(
      e.conversationId,
      current.copyWith(
        status: status,
        failure: failure,
        clearFailure: failure == null,
      ),
    );
  }

  Future<void> _drive(OutboxEntry entry) async {
    final id = entry.messageId;
    if (_running.containsKey(id)) return;
    final token = _running[id] = CancelToken();
    final progress = _progress[id] ??= TransferProgress();
    progress.update(0);
    try {
      await _run(entry, token, progress);
    } catch (e) {
      final code = e is ChatFailure ? e.code : 'FAILED';
      if (!_disposed) await _mark(entry, SendStatus.failed, code);
    } finally {
      _running.remove(id);
    }
  }

  Future<void> _run(
    OutboxEntry entry,
    CancelToken token,
    TransferProgress progress,
  ) async {
    final total = entry.attachment.full.ctSize + entry.attachment.thumb.ctSize;
    var done = 0;
    void report(int sent) =>
        progress.update(total == 0 ? 0 : (done + sent) / total);

    Future<void> upload(BlobRole role) async {
      final part = entry.part(role);
      final want = entry.attachment.part(role);
      final file = File('${dir.path}/${part.file}');
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } on FileSystemException {
        throw const ChatFailure(
          'LOCAL_DATA_LOST',
          'This photo can’t be sent again. Delete it and choose it again.',
        );
      }
      if (bytes.length != want.ctSize) {
        throw const ChatFailure(
          'LOCAL_DATA_LOST',
          'This photo can’t be sent again.',
        );
      }
      final slot = await api.createBlobSlot(
        entry.conversationId,
        role.name,
        want.ctSize,
        b64(want.ctSha256),
      );
      try {
        await transport.upload(
          slot,
          bytes,
          cancel: token,
          onProgress: (sent, _) => report(sent),
        );
      } catch (_) {
        // The slot is useless now; free its place among the pending ones.
        unawaited(_quietDelete(slot.blobId));
        rethrow;
      }
      part
        ..blobId = slot.blobId
        ..stage = PartStage.uploaded;
      await _save();
      done += want.ctSize;
      report(0);
    }

    Future<void> upToDate() async {
      for (final role in [BlobRole.thumb, BlobRole.full]) {
        final part = entry.part(role);
        if (part.stage == PartStage.ready) {
          await upload(role);
        } else {
          done += entry.attachment.part(role).ctSize;
        }
      }
      for (final role in [BlobRole.thumb, BlobRole.full]) {
        final part = entry.part(role);
        if (part.stage == PartStage.uploaded) {
          await api.completeBlob(part.blobId!);
          part.stage = PartStage.completed;
          await _save();
        }
      }
    }

    DateTime? serverAt;
    // One restart is allowed when the relay no longer has the blobs (a slot or
    // an unclaimed upload expires after an hour, or the stored size was
    // wrong): the ciphertext is still here, so it is uploaded again.
    for (var round = 0; round < 2; round++) {
      done = 0;
      try {
        await upToDate();
        final att = entry.attachment.withBlobs(
          fullId: entry.full.blobId,
          thumbId: entry.thumb.blobId,
        );
        serverAt = await deliver(
          entry.conversationId,
          entry.peerId,
          entry.messageId,
          {
            'v': 1,
            'kind': 'image',
            'text': entry.text,
            'messageId': entry.messageId,
            'conversationId': entry.conversationId,
            'senderId': userId,
            'sentAt': entry.sentAt.toIso8601String(),
            'att': att.toJson(),
            if (entry.reply != null) 're': entry.reply!.toJson(),
          },
          [att.full.blobId!, att.thumb.blobId!],
        );
        break;
      } on ChatFailure catch (e) {
        final stale =
            e.code == 'BLOB_NOT_READY' ||
            e.code == 'BLOB_SIZE_MISMATCH' ||
            e.code == 'BLOB_EXPIRED';
        if (!stale || round == 1) rethrow;
        for (final p in [entry.full, entry.thumb]) {
          final old = p.blobId;
          if (old != null) unawaited(_quietDelete(old));
          p
            ..blobId = null
            ..stage = PartStage.ready;
        }
        await _save();
      }
    }

    final sent = entry.attachment.withBlobs(
      fullId: entry.full.blobId,
      thumbId: entry.thumb.blobId,
    );
    final current = (await history.read(entry.conversationId))
        .where((m) => m.messageId == entry.messageId)
        .firstOrNull;
    await history.replace(
      entry.conversationId,
      ChatMessage(
        messageId: entry.messageId,
        senderId: userId,
        text: entry.text,
        sentAt: current?.sentAt ?? entry.sentAt,
        serverAt: serverAt,
        mine: true,
        attachment: sent,
        reply: current?.reply ?? entry.reply,
        reactionStates: current?.reactionStates ?? const {},
      ),
    );
    // The ciphertext that was just uploaded is already verified: keep it as
    // the cached copy, so our own photo opens without downloading it.
    try {
      await cache.adopt(
        blobCacheKey(
          entry.conversationId,
          sent.full.blobId!,
          sent.full.ctSha256,
        ),
        File('${dir.path}/${entry.full.file}'),
      );
      await cache.adopt(
        blobCacheKey(
          entry.conversationId,
          sent.thumb.blobId!,
          sent.thumb.ctSha256,
        ),
        File('${dir.path}/${entry.thumb.file}'),
      );
    } catch (_) {
      // The photo is sent; at worst it downloads once.
    }
    _entries.remove(entry.messageId);
    await _save();
    await _clean(entry.messageId);
    progress.update(1);
  }
}
