import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_cache.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/features/chat.dart' show chatError, photoFailureText;

import 'chat_photo_helpers.dart';

final picked = Uint8List.fromList([1, 2, 3, 4]);

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.dispose());

  Future<ChatMessage> send({String caption = ''}) =>
      h.outbox.enqueue(conv, peerId, picked, caption: caption);

  Future<ChatMessage> sendAndSettle() async {
    final m = await send();
    await h.outbox.settled(m.messageId);
    return m;
  }

  group('happy path', () {
    test('uploads both blobs, completes them and sends one message', () async {
      final m = await send(caption: 'look');
      // Shown at once, before anything has been uploaded.
      expect(m.status, SendStatus.sending);
      expect(m.attachment!.uploaded, isFalse);
      expect(h.outbox.localThumb(m.messageId), isNotNull);
      await h.outbox.settled(m.messageId);

      final sent = await h.messageOf(m.messageId);
      expect(sent.status, SendStatus.sent);
      expect(sent.failure, isNull);
      expect(sent.serverAt, isNotNull);
      expect(sent.attachment!.uploaded, isTrue);
      expect((await h.history.read(conv)), hasLength(1));

      // The order the contract describes: thumb, then full, both completed.
      final slots = h.cloud.slots.values.toList();
      expect(slots.map((s) => s.role), ['thumb', 'full']);
      expect(h.cloud.calls.where((c) => !c.startsWith('url')), [
        'slot thumb',
        'upload ${slots[0].id}',
        'slot full',
        'upload ${slots[1].id}',
        'complete ${slots[0].id}',
        'complete ${slots[1].id}',
      ]);
      // PUT with exactly the headers the slot returned.
      for (final headers in h.cloud.uploadHeaders) {
        expect(headers.keys.toSet(), {'Content-Type', 'x-amz-checksum-sha256'});
        expect(headers['Content-Type'], 'application/octet-stream');
      }

      // The relay got a v1 image payload whose descriptor validates strictly
      // and names the blobs it was sent with.
      final payload = h.relay.stored[m.messageId]!;
      expect(payload['v'], 1);
      expect(payload['kind'], 'image');
      expect(payload['text'], 'look');
      expect(payload['senderId'], meId);
      expect(payload['conversationId'], conv);
      final att = ChatAttachment.parse(jsonDecode(jsonEncode(payload['att'])));
      expect(att.caption, 'look');
      expect(att.full.blobId, slots[1].id);
      expect(att.thumb.blobId, slots[0].id);
      expect(h.relay.blobIdsOf[m.messageId], [slots[1].id, slots[0].id]);
      // Ciphertext sizes are what was uploaded and what the slot declared.
      expect(att.full.ctSize, h.cloud.objects[slots[1].id]!.length);
      expect(att.thumb.ctSize, h.cloud.objects[slots[0].id]!.length);
      expect(slots[1].size, att.full.ctSize);

      // The key and the salt reach the receiver: it can open what was uploaded.
      final plain = await h.codec.decrypt(
        key: att.key,
        role: 'full',
        salt: att.salt,
        conversationId: conv,
        mime: att.mime,
        chunkSize: att.chunk,
        plainLen: att.full.plainLen,
        ctSha256: att.full.ctSha256,
        ciphertext: h.cloud.objects[att.full.blobId]!,
      );
      expect(jpegSizeOk(plain), isTrue);
      // The same ciphertext cannot be opened as the other role or elsewhere.
      await expectLater(
        h.codec.decrypt(
          key: att.key,
          role: 'full',
          salt: att.salt,
          conversationId: 'other',
          mime: att.mime,
          chunkSize: att.chunk,
          plainLen: att.full.plainLen,
          ctSha256: att.full.ctSha256,
          ciphertext: h.cloud.objects[att.full.blobId]!,
        ),
        throwsException,
      );

      // Local state is cleaned up and the verified ciphertext is kept as cache.
      expect(h.outbox.pending, isEmpty);
      expect(h.outboxDir.existsSync() ? h.outboxDir.listSync() : [], isEmpty);
      String key(BlobPart part) =>
          blobCacheKey(conv, part.blobId!, part.ctSha256);
      expect(await h.cache.has(key(att.full)), isTrue);
      expect(await h.cache.has(key(att.thumb)), isTrue);
      expect(h.outbox.progress(m.messageId)!.value, 1);
    });

    test('without a caption the text is the fallback for older apps', () async {
      final m = await sendAndSettle();
      expect(h.relay.stored[m.messageId]!['text'], photoFallbackText);
      expect((h.relay.stored[m.messageId]!['att'] as Map)['caption'], '');
    });

    test('every photo gets its own key, salt and message id', () async {
      final a = await sendAndSettle(), b = await sendAndSettle();
      expect(a.messageId, isNot(b.messageId));
      expect(a.attachment!.key, isNot(b.attachment!.key));
      expect(a.attachment!.salt, isNot(b.attachment!.salt));
    });

    test('nothing in the stored outbox or history is a signed URL', () async {
      final m = await send();
      await h.outbox.settled(m.messageId);
      for (final value in h.store.values.values) {
        expect(value, isNot(contains('storage.invalid')));
        expect(value, isNot(contains('sig=')));
      }
    });
  });

  group('refused before anything is saved', () {
    test('a ciphertext over the full cap says so before any slot', () async {
      h.codec.fullBytes = Uint8List(maxFullCiphertext);
      await expectLater(
        send(),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'PHOTO_TOO_LARGE'),
        ),
      );
      expect(h.cloud.calls, isEmpty);
      expect(await h.history.read(conv), isEmpty);
      expect(h.outbox.pending, isEmpty);
      expect(h.outboxDir.existsSync(), isFalse);
    });

    test('a thumbnail over its cap is refused the same way', () async {
      h.codec.thumbBytes = Uint8List(maxThumbCiphertext);
      await expectLater(send(), throwsA(isA<ChatFailure>()));
      expect(h.cloud.calls, isEmpty);
    });

    test('an input over 64 MiB is refused before it is decoded', () async {
      await expectLater(
        h.outbox.enqueue(conv, peerId, Uint8List(maxPhotoInput + 1)),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'PHOTO_TOO_LARGE'),
        ),
      );
      expect(h.codec.keys, 0);
    });

    test('an unreadable photo is a clear message, not a crash', () async {
      h.codec.prepareFails = true;
      await expectLater(
        send(),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'PHOTO_UNREADABLE'),
        ),
      );
      expect(await h.history.read(conv), isEmpty);
    });
  });

  group('failure at each step, then resume', () {
    const offline = ChatFailure('NETWORK', 'offline');
    // (name, arrange, slots ever created, uploads ever made)
    final steps = <(String, void Function(Harness), int, int)>[
      ('first slot request', (h) => h.cloud.failCall('slot', 1, offline), 2, 2),
      (
        'second slot request',
        (h) => h.cloud.failCall('slot', 2, offline),
        2,
        2,
      ),
      ('thumbnail upload', (h) => h.cloud.failCall('upload', 1, offline), 3, 3),
      ('full upload', (h) => h.cloud.failCall('upload', 2, offline), 3, 3),
      ('first complete', (h) => h.cloud.failCall('complete', 1, offline), 2, 2),
      (
        'second complete',
        (h) => h.cloud.failCall('complete', 2, offline),
        2,
        2,
      ),
      ('message', (h) => h.relay.failures.add(offline), 2, 2),
    ];
    for (final (name, arrange, slots, uploads) in steps) {
      test('$name fails, retry finishes without duplicates', () async {
        arrange(h);
        final m = await send();
        await h.outbox.settled(m.messageId);
        final failed = await h.messageOf(m.messageId);
        expect(failed.status, SendStatus.failed);
        expect(failed.failure, 'NETWORK');
        // The photo stays in the list, with its files, ready to resume.
        expect(h.outbox.pending, hasLength(1));
        expect(
          File('${h.outboxDir.path}/${m.messageId}/full.bin').existsSync(),
          isTrue,
        );
        expect(h.relay.stored, isEmpty);

        await h.outbox.retry(conv, m.messageId);
        await h.outbox.settled(m.messageId);
        final done = await h.messageOf(m.messageId);
        expect(done.status, SendStatus.sent);
        expect(done.failure, isNull);

        // One message, delivered once, with two live blobs; a step that had
        // finished was not done again.
        expect(await h.history.read(conv), hasLength(1));
        expect(h.relay.stored, hasLength(1));
        expect(h.cloud.slots, hasLength(slots));
        expect(h.cloud.count('upload'), uploads);
        expect(h.cloud.live, hasLength(2));
        expect(h.cloud.live.every((s) => s.completed), isTrue);
        expect(h.cloud.claimed, hasLength(2));
        expect(h.outbox.pending, isEmpty);
      });
    }

    test('deliver failing leaves the uploads alone for the retry', () async {
      h.relay.failures.add(const ChatFailure('NETWORK', 'offline'));
      final m = await sendAndSettle();
      final slotsBefore = h.cloud.slots.keys.toList();
      await h.outbox.retry(conv, m.messageId);
      await h.outbox.settled(m.messageId);
      expect(h.cloud.slots.keys.toList(), slotsBefore);
      expect(h.cloud.count('upload'), 2);
      expect(h.cloud.count('complete'), 2);
    });

    test('a lost reply is not a second message', () async {
      h.relay.loseReply = true;
      final m = await sendAndSettle();
      expect((await h.messageOf(m.messageId)).status, SendStatus.failed);
      await h.outbox.retry(conv, m.messageId);
      await h.outbox.settled(m.messageId);
      expect((await h.messageOf(m.messageId)).status, SendStatus.sent);
      expect(h.relay.stored, hasLength(1));
      expect(h.cloud.slots, hasLength(2));
      expect(await h.history.read(conv), hasLength(1));
    });

    test('a failed upload frees its slot', () async {
      h.cloud.failNext('upload', const ChatFailure('NETWORK', 'offline'));
      final m = await sendAndSettle();
      expect(h.cloud.calls.where((c) => c.startsWith('delete')), hasLength(1));
      await h.outbox.retry(conv, m.messageId);
      await h.outbox.settled(m.messageId);
      expect((await h.messageOf(m.messageId)).status, SendStatus.sent);
    });
  });

  group('the relay no longer has the blobs', () {
    test('uploads again from the saved ciphertext and sends once', () async {
      // The unclaimed upload expired between the steps: the relay answers the
      // send with BLOB_NOT_READY.
      h.relay.failures.add(
        const ChatFailure('BLOB_NOT_READY', 'Finish uploading', 409),
      );
      final m = await sendAndSettle();
      final done = await h.messageOf(m.messageId);
      expect(done.status, SendStatus.sent);
      expect(h.cloud.slots, hasLength(4));
      expect(h.cloud.live, hasLength(2));
      expect(h.relay.stored, hasLength(1));
      expect(
        done.attachment!.full.blobId,
        h.relay.blobIdsOf[m.messageId]!.first,
      );
      // The key and ciphertext did not change; only the blob ids did.
      expect(h.codec.encrypted, hasLength(2));
    });

    test('a size mismatch on complete restarts the uploads once', () async {
      h.cloud.failNext(
        'complete',
        const ChatFailure('BLOB_SIZE_MISMATCH', 'size', 409),
      );
      final m = await sendAndSettle();
      expect((await h.messageOf(m.messageId)).status, SendStatus.sent);
      expect(h.cloud.slots, hasLength(4));
    });

    test(
      'a second stale answer fails the message instead of looping',
      () async {
        h.relay.failures.addAll([
          const ChatFailure('BLOB_NOT_READY', 'x', 409),
          const ChatFailure('BLOB_NOT_READY', 'x', 409),
        ]);
        final m = await sendAndSettle();
        final failed = await h.messageOf(m.messageId);
        expect(failed.status, SendStatus.failed);
        expect(failed.failure, 'BLOB_NOT_READY');
      },
    );
  });

  group('restart', () {
    test('an interrupted upload resumes with the same ids', () async {
      // The full image never finishes: the app is closed while it uploads.
      h.cloud.gate = Completer<void>();
      final m = await send();
      for (var i = 0; i < 50 && h.cloud.count('upload') < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(h.cloud.count('upload'), 1);
      h.restart();
      h.cloud.gate = null;
      await h.outbox.load();

      // After the restart the photo is waiting, not silently sending.
      final waiting = await h.messageOf(m.messageId);
      expect(waiting.status, SendStatus.failed);
      expect(waiting.failure, 'INTERRUPTED');
      expect(h.outbox.pending.single.messageId, m.messageId);
      final key = waiting.attachment!.key;

      await h.outbox.retry(conv, m.messageId);
      await h.outbox.settled(m.messageId);
      final done = await h.messageOf(m.messageId);
      expect(done.status, SendStatus.sent);
      expect(done.attachment!.key, key);
      expect(await h.history.read(conv), hasLength(1));
      expect(h.relay.stored, hasLength(1));
      // The thumbnail had gone up before the restart.
      expect(h.cloud.live.where((s) => s.completed), hasLength(2));
    });

    test('a finished upload resumes at the message step', () async {
      h.relay.failures.add(const ChatFailure('NETWORK', 'offline'));
      final m = await sendAndSettle();
      h.restart();
      await h.outbox.load();
      final slots = h.cloud.slots.length;
      await h.outbox.retry(conv, m.messageId);
      await h.outbox.settled(m.messageId);
      expect(h.cloud.slots.length, slots);
      expect((await h.messageOf(m.messageId)).status, SendStatus.sent);
    });

    test('the outbox keeps no absolute paths', () async {
      h.relay.failures.add(const ChatFailure('NETWORK', 'offline'));
      await sendAndSettle();
      final stored = h.store.values['outbox']!;
      expect(stored, isNot(contains(h.root.path)));
      expect(stored, contains('/full.bin'));
    });

    test('lost files make the retry say so and the photo deletable', () async {
      h.relay.failures.add(const ChatFailure('NETWORK', 'offline'));
      h.cloud.failNext('slot', const ChatFailure('NETWORK', 'offline'));
      final m = await sendAndSettle();
      await h.outboxDir.delete(recursive: true);
      await h.outbox.retry(conv, m.messageId);
      await h.outbox.settled(m.messageId);
      expect((await h.messageOf(m.messageId)).failure, 'LOCAL_DATA_LOST');
      await h.outbox.discard(conv, m.messageId);
      expect(await h.history.read(conv), isEmpty);
    });
  });

  group('cancel, delete and sign-out', () {
    test('cancel stops the upload and leaves a retryable message', () async {
      h.cloud.gate = Completer<void>();
      final m = await send();
      for (var i = 0; i < 50 && h.cloud.count('upload') < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      h.outbox.cancel(m.messageId);
      await h.outbox.settled(m.messageId);
      final failed = await h.messageOf(m.messageId);
      expect(failed.status, SendStatus.failed);
      expect(failed.failure, 'CANCELED');
      expect(h.relay.stored, isEmpty);

      h.cloud.gate = null;
      await h.outbox.retry(conv, m.messageId);
      await h.outbox.settled(m.messageId);
      expect((await h.messageOf(m.messageId)).status, SendStatus.sent);
      expect(h.relay.stored, hasLength(1));
    });

    test('delete removes the message, files and uploaded blobs', () async {
      h.relay.failures.add(const ChatFailure('NETWORK', 'offline'));
      final m = await sendAndSettle();
      expect(h.cloud.live, hasLength(2));
      await h.outbox.discard(conv, m.messageId);
      await Future<void>.delayed(Duration.zero);
      expect(await h.history.read(conv), isEmpty);
      expect(h.outbox.pending, isEmpty);
      expect(
        h.outboxDir.existsSync() && h.outboxDir.listSync().isNotEmpty,
        isFalse,
      );
      expect(h.cloud.live, isEmpty);
      expect(h.outbox.localThumb(m.messageId), isNull);
    });

    test('sign-out wipes unsent uploads, the outbox and the cache', () async {
      h.relay.failures.add(const ChatFailure('NETWORK', 'offline'));
      await sendAndSettle();
      await sendAndSettle();
      expect(h.cache.root.existsSync(), isTrue);
      await h.outbox.wipe();
      await h.cache.wipe();
      expect(h.outboxDir.existsSync(), isFalse);
      expect(h.cache.root.existsSync(), isFalse);
      expect(h.store.values.containsKey('outbox'), isFalse);
    });

    test('wiping without an engine removes the same things', () async {
      h.relay.failures.add(const ChatFailure('NETWORK', 'offline'));
      await sendAndSettle();
      await ChatEngine.wipeLocalMedia(
        root: h.root,
        store: h.store..values['hiyall.chat.$meId.outbox'] = '[]',
        userId: meId,
      );
      expect(Directory('${h.root.path}/chat_outbox').existsSync(), isFalse);
      expect(Directory('${h.root.path}/chat_blobs').existsSync(), isFalse);
      expect(h.store.values.containsKey('hiyall.chat.$meId.outbox'), isFalse);
    });
  });

  group('server answers become calm messages', () {
    test('the reply-or-friend gate', () async {
      h.cloud.failNext(
        'slot',
        const ChatFailure('ATTACHMENTS_NOT_ALLOWED', 'raw server text', 403),
      );
      final m = await sendAndSettle();
      final failed = await h.messageOf(m.messageId);
      expect(failed.failure, 'ATTACHMENTS_NOT_ALLOWED');
      expect(
        photoFailureText(failed.failure),
        'You can send photos, voice messages and videos once they reply.',
      );
    });

    test('each documented code has human words', () {
      for (final (code, status) in [
        ('ATTACHMENTS_NOT_ALLOWED', 403),
        ('MESSAGES_NOT_ALLOWED', 403),
        ('NOT_FOUND', 404),
        ('BLOB_NOT_READY', 409),
        ('BLOB_SIZE_MISMATCH', 409),
        ('BLOB_EXPIRED', 410),
        ('TOO_LARGE', 413),
        ('RATE_LIMITED', 429),
        ('QUOTA', 429),
        ('CHAT_MEDIA_UNAVAILABLE', 503),
        ('NETWORK', null),
      ]) {
        final text = chatError(ChatFailure(code, 'server words $code', status));
        expect(text, isNotEmpty, reason: code);
        expect(text, isNot(contains(code)), reason: code);
      }
      expect(
        chatError(const ChatFailure('ATTACHMENTS_NOT_ALLOWED', 'x', 403)),
        'You can send photos, voice messages and videos once they reply.',
      );
      expect(
        chatError(const ChatFailure('QUOTA', 'x', 429)),
        contains('a lot of media'),
      );
      expect(
        chatError(const ChatFailure('CHAT_MEDIA_UNAVAILABLE', 'x', 503)),
        contains('aren’t available'),
      );
    });

    test(
      'a server cap refusal is a failed message with the right code',
      () async {
        h.cloud.failNext('slot', const ChatFailure('TOO_LARGE', 'big', 413));
        final m = await sendAndSettle();
        expect((await h.messageOf(m.messageId)).failure, 'TOO_LARGE');
      },
    );
  });
}

bool jpegSizeOk(Uint8List b) => b.length > 100 && b[0] == 0xFF && b[1] == 0xD8;
