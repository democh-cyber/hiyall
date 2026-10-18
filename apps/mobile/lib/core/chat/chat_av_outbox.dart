import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'chat_api.dart';
import 'chat_attachment.dart';
import 'chat_av.dart';
import 'chat_blob_cache.dart';
import 'chat_blob_codec.dart';
import 'chat_blob_transport.dart';
import 'chat_engine.dart';
import 'chat_history.dart';
import 'chat_outbox.dart' show PartStage, PhotoDeliver, TransferProgress;
import 'chat_reactions.dart';
import 'chat_store.dart';

/// A recorded voice message, ready to seal: the AAC/M4A bytes, how long it is and its waveform.
class VoiceClip {
  final Uint8List bytes;
  final int durationMs;
  final Uint8List wave;
  const VoiceClip({
    required this.bytes,
    required this.durationMs,
    required this.wave,
  });
}

/// A video ready to seal: the re-encoded MP4 (metadata already scrubbed), its picture size and length, and the
/// poster frame prepared like a photo (a JPEG thumbnail and a tiny preview).
class PreparedVideo {
  final Uint8List bytes;
  final int w, h, durationMs;
  final Uint8List poster, preview;
  final int posterW, posterH;
  const PreparedVideo({
    required this.bytes,
    required this.w,
    required this.h,
    required this.durationMs,
    required this.poster,
    required this.posterW,
    required this.posterH,
    required this.preview,
  });
}

/// One ciphertext file of an unsent voice message or video, and how far it got.
class AvPart {
  /// `voice`, `video` or `thumb`: the blob's role.
  final String role;

  /// Relative to the outbox folder.
  final String file;
  PartStage stage;
  String? blobId;
  AvPart(this.role, this.file, {this.stage = PartStage.ready, this.blobId});
  Map<String, dynamic> toJson() => {
    'role': role,
    'file': file,
    'stage': stage.index,
    'blob': ?blobId,
  };
  factory AvPart.fromJson(Map<String, dynamic> j) => AvPart(
    j['role'] as String,
    j['file'] as String,
    stage: PartStage.values[j['stage'] as int],
    blobId: j['blob'] as String?,
  );
}

/// One voice message or video on its way out. Everything needed to resume lives here and on disk: the key, the
/// ids and each blob's progress, plus the ciphertext files.
class AvEntry {
  final String messageId, conversationId, peerId;
  final DateTime sentAt;
  final VoiceAttachment? voice;
  final VideoAttachment? video;
  final List<AvPart> parts;
  final ChatReply? reply;
  AvEntry({
    required this.messageId,
    required this.conversationId,
    required this.peerId,
    required this.sentAt,
    required this.parts,
    this.voice,
    this.video,
    this.reply,
  }) : assert((voice == null) != (video == null));

  bool get isVoice => voice != null;
  String get kind => isVoice ? 'voice' : 'video';
  String get text => isVoice ? voiceFallbackText : videoFallbackText;

  MediaPart partOf(String role) => switch (role) {
    'voice' => voice!.part,
    'video' => video!.video,
    _ => video!.poster,
  };

  Map<String, dynamic> toJson() => {
    'id': messageId,
    'conv': conversationId,
    'peer': peerId,
    'at': sentAt.toIso8601String(),
    'kind': kind,
    'att': isVoice ? voice!.toLocalJson() : video!.toLocalJson(),
    'parts': [for (final p in parts) p.toJson()],
    if (reply != null) 're': reply!.toJson(),
  };

  factory AvEntry.fromJson(Map<String, dynamic> j) {
    final voice = j['kind'] == 'voice';
    return AvEntry(
      messageId: j['id'] as String,
      conversationId: j['conv'] as String,
      peerId: j['peer'] as String,
      sentAt: DateTime.parse(j['at'] as String),
      voice: voice ? VoiceAttachment.fromLocal(j['att']) : null,
      video: voice ? null : VideoAttachment.fromLocal(j['att']),
      parts: [
        for (final p in j['parts'] as List)
          AvPart.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
      reply: ChatReply.parse(j['re']),
    );
  }
}

/// Sends voice messages and videos: seal, upload, complete, then the message. Every step is saved before the
/// next, so a retry resumes with the same message id and the same blobs instead of duplicating either. Uploads
/// run outside the engine's Olm lock; only the final delivery takes it. It mirrors [PhotoOutbox].
class AvOutbox {
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
  AvOutbox({
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

  final _entries = <String, AvEntry>{};
  final _running = <String, CancelToken>{};
  final _progress = <String, TransferProgress>{};
  final _posters = <String, Uint8List>{};
  final _runs = <String, Future<void>>{};
  final _preparing = <Future<void>>{};
  Future<void>? _loaded;
  Future<void> _saving = Future.value();
  bool _disposed = false;

  Future<void> load() => _loaded ??= () async {
    final raw = await store.read(storeKey);
    if (raw == null) return;
    for (final item in jsonDecode(raw) as List) {
      try {
        final e = AvEntry.fromJson(Map<String, dynamic>.from(item as Map));
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

  /// Stops every upload and all further writes; what was in flight stays saved as it was.
  void dispose() {
    _disposed = true;
    for (final t in _running.values) {
      t.cancel();
    }
  }

  /// Completes when every upload that was running has stopped.
  Future<void> drain() async {
    await Future.wait([
      ..._preparing,
      for (final run in _runs.values) run.then<void>((_) {}, onError: (_) {}),
    ]);
  }

  void _open() {
    if (_disposed) {
      throw const ChatFailure('DISPOSED', 'The chat was closed.');
    }
  }

  List<AvEntry> get pending => List.unmodifiable(_entries.values);
  bool isRunning(String messageId) => _running.containsKey(messageId);
  TransferProgress? progress(String messageId) => _progress[messageId];

  /// The poster of a video sent in this session, so it shows at once.
  Uint8List? localPoster(String messageId) => _posters[messageId];

  Directory _folder(String messageId) => Directory('${dir.path}/$messageId');

  Future<T> _tracked<T>(Future<T> Function() work) {
    _open();
    final run = work();
    final done = run.then<void>((_) {}, onError: (_) {});
    _preparing.add(done);
    done.whenComplete(() => _preparing.remove(done));
    return run;
  }

  Future<SealedPart> _seal(
    List<int> key,
    String role,
    String salt,
    String conversationId,
    String mime,
    Uint8List plain,
  ) => codec.encrypt(
    key: key,
    role: role,
    salt: salt,
    conversationId: conversationId,
    mime: mime,
    chunkSize: attachmentChunk,
    plaintext: plain,
  );

  Future<ChatMessage> enqueueVoice(
    String conversationId,
    String peerId,
    VoiceClip clip, {
    ChatMessage? replyTo,
  }) => _tracked(() => _enqueueVoice(conversationId, peerId, clip, replyTo));

  Future<ChatMessage> enqueueVideo(
    String conversationId,
    String peerId,
    PreparedVideo video, {
    ChatMessage? replyTo,
  }) => _tracked(() => _enqueueVideo(conversationId, peerId, video, replyTo));

  Future<ChatMessage> _enqueueVoice(
    String conversationId,
    String peerId,
    VoiceClip clip,
    ChatMessage? replyTo,
  ) async {
    await load();
    if (clip.durationMs < minVoiceSendMs || clip.durationMs > maxVoiceMs) {
      throw const ChatFailure(
        'VOICE_LENGTH',
        'Voice messages can be up to 5 minutes long.',
      );
    }
    if (clip.wave.isEmpty || clip.wave.length > maxWaveBytes) {
      throw const ChatFailure(
        'VOICE_UNREADABLE',
        'That recording can’t be sent.',
      );
    }
    if (clip.bytes.isEmpty || clip.bytes.length > maxVoiceCiphertext) {
      throw const ChatFailure(
        'VOICE_TOO_LARGE',
        'That voice message is too large to send.',
      );
    }
    final key = codec.generateKey(), salt = newUuid4(_random);
    final messageId = newUuid4(_random);
    final sealed = await _seal(
      key,
      'voice',
      salt,
      conversationId,
      voiceMime,
      clip.bytes,
    );
    if (sealed.ciphertext.length > maxVoiceCiphertext) {
      throw const ChatFailure(
        'VOICE_TOO_LARGE',
        'That voice message is too large to send.',
      );
    }
    final att = VoiceAttachment(
      key: key,
      salt: salt,
      chunk: attachmentChunk,
      part: MediaPart(
        blobId: null,
        plainLen: sealed.plainLen,
        ctSize: sealed.ciphertext.length,
        ctSha256: sealed.ctSha256,
      ),
      durationMs: clip.durationMs,
      wave: clip.wave,
    );
    _open();
    final folder = _folder(messageId);
    await folder.create(recursive: true);
    await File('${folder.path}/voice.bin')
        .writeAsBytes(sealed.ciphertext, flush: true);
    final entry = AvEntry(
      messageId: messageId,
      conversationId: conversationId,
      peerId: peerId,
      sentAt: DateTime.now().toUtc(),
      voice: att,
      parts: [AvPart('voice', '$messageId/voice.bin')],
      reply: replyTo == null ? null : replyOf(replyTo, userId),
    );
    return _begin(entry);
  }

  Future<ChatMessage> _enqueueVideo(
    String conversationId,
    String peerId,
    PreparedVideo video,
    ChatMessage? replyTo,
  ) async {
    await load();
    if (video.durationMs < minMediaMs || video.durationMs > maxVideoMs) {
      throw const ChatFailure(
        'VIDEO_LENGTH',
        'Videos can be up to 1 minute long.',
      );
    }
    if (video.bytes.isEmpty || video.bytes.length > maxVideoPlain) {
      throw const ChatFailure(
        'VIDEO_TOO_LARGE',
        'That video is too large to send. Try a shorter one.',
      );
    }
    final key = codec.generateKey(), salt = newUuid4(_random);
    final messageId = newUuid4(_random);
    final poster = await _seal(
      key,
      'thumb',
      salt,
      conversationId,
      attachmentMime,
      video.poster,
    );
    final main = await _seal(
      key,
      'video',
      salt,
      conversationId,
      videoMime,
      video.bytes,
    );
    // The padded ciphertext is a little larger than the file: the server's caps are checked on what would
    // actually be uploaded.
    if (main.ciphertext.length > maxVideoCiphertext ||
        poster.ciphertext.length > maxThumbCiphertext) {
      throw const ChatFailure(
        'VIDEO_TOO_LARGE',
        'That video is too large to send. Try a shorter one.',
      );
    }
    final att = VideoAttachment(
      key: key,
      salt: salt,
      chunk: attachmentChunk,
      video: MediaPart(
        blobId: null,
        plainLen: main.plainLen,
        ctSize: main.ciphertext.length,
        ctSha256: main.ctSha256,
      ),
      poster: MediaPart(
        blobId: null,
        plainLen: poster.plainLen,
        ctSize: poster.ciphertext.length,
        ctSha256: poster.ctSha256,
      ),
      w: video.w,
      h: video.h,
      posterW: video.posterW,
      posterH: video.posterH,
      durationMs: video.durationMs,
      preview: video.preview,
    );
    _open();
    final folder = _folder(messageId);
    await folder.create(recursive: true);
    await File('${folder.path}/thumb.bin')
        .writeAsBytes(poster.ciphertext, flush: true);
    await File('${folder.path}/video.bin')
        .writeAsBytes(main.ciphertext, flush: true);
    _posters[messageId] = video.poster;
    while (_posters.length > 8) {
      _posters.remove(_posters.keys.first);
    }
    final entry = AvEntry(
      messageId: messageId,
      conversationId: conversationId,
      peerId: peerId,
      sentAt: DateTime.now().toUtc(),
      video: att,
      parts: [
        AvPart('thumb', '$messageId/thumb.bin'),
        AvPart('video', '$messageId/video.bin'),
      ],
      reply: replyTo == null ? null : replyOf(replyTo, userId),
    );
    return _begin(entry);
  }

  Future<ChatMessage> _begin(AvEntry entry) async {
    _entries[entry.messageId] = entry;
    await _save();
    final message = ChatMessage(
      messageId: entry.messageId,
      senderId: userId,
      text: entry.text,
      sentAt: entry.sentAt,
      mine: true,
      voice: entry.voice,
      video: entry.video,
      status: SendStatus.sending,
      reply: entry.reply,
    );
    await history.append(entry.conversationId, message);
    _start(entry);
    return message;
  }

  /// Resumes a failed message from the step it stopped at.
  Future<void> retry(String conversationId, String messageId) async {
    _open();
    await load();
    final entry = _entries[messageId];
    if (entry == null) {
      throw const ChatFailure(
        'LOCAL_DATA_LOST',
        'This message can’t be sent again. Delete it and send it again.',
      );
    }
    if (_running.containsKey(messageId)) return;
    await _mark(entry, SendStatus.sending);
    _start(entry);
  }

  void _start(AvEntry entry) => _runs[entry.messageId] = _drive(entry);

  /// Completes when the upload of this message is not running (tests).
  Future<void> settled(String messageId) => _runs[messageId] ?? Future.value();

  /// Stops an upload in flight; the message stays as failed, ready to retry.
  void cancel(String messageId) => _running[messageId]?.cancel();

  /// Removes a message that never went out: its entry, files and any blob already uploaded.
  Future<void> discard(String conversationId, String messageId) async {
    await load();
    _running[messageId]?.cancel();
    final entry = _entries.remove(messageId);
    _progress.remove(messageId)?.close();
    _posters.remove(messageId);
    if (entry != null) {
      await _save();
      for (final p in entry.parts) {
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

  /// Sign-out: nothing of an unsent message stays on the device.
  Future<void> wipe() async {
    for (final t in _running.values) {
      t.cancel();
    }
    _entries.clear();
    for (final p in _progress.values) {
      p.close();
    }
    _progress.clear();
    _posters.clear();
    await store.delete(storeKey);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }

  Future<void> _mark(AvEntry e, SendStatus status, [String? failure]) async {
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

  Future<void> _drive(AvEntry entry) async {
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
    AvEntry entry,
    CancelToken token,
    TransferProgress progress,
  ) async {
    final total = entry.parts.fold<int>(
      0,
      (sum, p) => sum + entry.partOf(p.role).ctSize,
    );
    var done = 0;
    void report(int sent) =>
        progress.update(total == 0 ? 0 : (done + sent) / total);

    Future<void> upload(AvPart part) async {
      final want = entry.partOf(part.role);
      final file = File('${dir.path}/${part.file}');
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } on FileSystemException {
        throw const ChatFailure(
          'LOCAL_DATA_LOST',
          'This message can’t be sent again. Delete it and send it again.',
        );
      }
      if (bytes.length != want.ctSize) {
        throw const ChatFailure(
          'LOCAL_DATA_LOST',
          'This message can’t be sent again.',
        );
      }
      final slot = await api.createBlobSlot(
        entry.conversationId,
        part.role,
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
      for (final part in entry.parts) {
        if (part.stage == PartStage.ready) {
          await upload(part);
        } else {
          done += entry.partOf(part.role).ctSize;
        }
      }
      for (final part in entry.parts) {
        if (part.stage == PartStage.uploaded) {
          await api.completeBlob(part.blobId!);
          part.stage = PartStage.completed;
          await _save();
        }
      }
    }

    String idOf(String role) =>
        entry.parts.firstWhere((p) => p.role == role).blobId!;

    DateTime? serverAt;
    // One restart is allowed when the relay no longer has the blobs (a slot or an unclaimed upload expires
    // after an hour, or the stored size was wrong): the ciphertext is still here, so it is uploaded again.
    for (var round = 0; round < 2; round++) {
      done = 0;
      try {
        await upToDate();
        final Map<String, dynamic> att;
        final List<String> blobIds;
        if (entry.isVoice) {
          att = entry.voice!.withBlob(idOf('voice')).toJson();
          blobIds = [idOf('voice')];
        } else {
          att = entry.video!
              .withBlobs(videoId: idOf('video'), posterId: idOf('thumb'))
              .toJson();
          blobIds = [idOf('video'), idOf('thumb')];
        }
        serverAt = await deliver(
          entry.conversationId,
          entry.peerId,
          entry.messageId,
          {
            'v': 1,
            'kind': entry.kind,
            'text': entry.text,
            'messageId': entry.messageId,
            'conversationId': entry.conversationId,
            'senderId': userId,
            'sentAt': entry.sentAt.toIso8601String(),
            'att': att,
            if (entry.reply != null) 're': entry.reply!.toJson(),
          },
          blobIds,
        );
        break;
      } on ChatFailure catch (e) {
        final stale =
            e.code == 'BLOB_NOT_READY' ||
            e.code == 'BLOB_SIZE_MISMATCH' ||
            e.code == 'BLOB_EXPIRED';
        if (!stale || round == 1) rethrow;
        for (final p in entry.parts) {
          final old = p.blobId;
          if (old != null) unawaited(_quietDelete(old));
          p
            ..blobId = null
            ..stage = PartStage.ready;
        }
        await _save();
      }
    }

    final VoiceAttachment? voice = entry.isVoice
        ? entry.voice!.withBlob(idOf('voice'))
        : null;
    final VideoAttachment? video = entry.isVoice
        ? null
        : entry.video!.withBlobs(
            videoId: idOf('video'),
            posterId: idOf('thumb'),
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
        voice: voice,
        video: video,
        reply: current?.reply ?? entry.reply,
        reactionStates: current?.reactionStates ?? const {},
      ),
    );
    // The ciphertext that was just uploaded is already verified: keep it as the cached copy, so our own
    // message plays without downloading it.
    try {
      for (final p in entry.parts) {
        final part = entry.partOf(p.role);
        await cache.adopt(
          blobCacheKey(entry.conversationId, idOf(p.role), part.ctSha256),
          File('${dir.path}/${p.file}'),
        );
      }
    } catch (_) {
      // The message is sent; at worst it downloads once.
    }
    _entries.remove(entry.messageId);
    await _save();
    await _clean(entry.messageId);
    progress.update(1);
  }
}
