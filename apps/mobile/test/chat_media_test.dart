import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_cache.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_media.dart';

import 'chat_photo_helpers.dart';

void main() {
  late FakeCloud cloud;
  late FakeCodec codec;
  late Directory dir;
  late ChatBlobCache cache;
  late ChatMedia media;
  final fullJpeg = fakeJpeg(1536, 2048, extra: 3000);
  final thumbJpeg = fakeJpeg(240, 320, extra: 200);

  setUp(() {
    cloud = FakeCloud();
    codec = FakeCodec();
    dir = Directory.systemTemp.createTempSync('hiyall_media_test');
    cache = ChatBlobCache(Directory('${dir.path}/chat_blobs'));
    media = ChatMedia(api: cloud, transport: cloud, codec: codec, cache: cache);
  });
  tearDown(() => dir.delete(recursive: true));

  String keyOf(ChatAttachment att, BlobRole role) =>
      blobCacheKey(conv, att.part(role).blobId!, att.part(role).ctSha256);

  /// A photo as a peer sent it: sealed, uploaded, completed.
  Future<ChatAttachment> received() async {
    final key = codec.generateKey(), salt = newUuid4Fixed(codec.keys);
    Future<(BlobPart, SealedPart)> upload(
      String role,
      Uint8List plain,
      int w,
      int h,
    ) async {
      final sealed = await codec.encrypt(
        key: key,
        role: role,
        salt: salt,
        conversationId: conv,
        mime: attachmentMime,
        chunkSize: attachmentChunk,
        plaintext: plain,
      );
      final slot = await cloud.createBlobSlot(
        conv,
        role,
        sealed.ciphertext.length,
        b64(sealed.ctSha256),
      );
      await cloud.upload(slot, sealed.ciphertext);
      await cloud.completeBlob(slot.blobId);
      return (
        BlobPart(
          blobId: slot.blobId,
          w: w,
          h: h,
          plainLen: sealed.plainLen,
          ctSize: sealed.ciphertext.length,
          ctSha256: sealed.ctSha256,
        ),
        sealed,
      );
    }

    final (full, _) = await upload('full', fullJpeg, 1536, 2048);
    final (thumb, _) = await upload('thumb', thumbJpeg, 240, 320);
    cloud.calls.clear();
    return ChatAttachment(
      key: key,
      salt: salt,
      mime: attachmentMime,
      chunk: attachmentChunk,
      full: full,
      thumb: thumb,
      preview: Uint8List(21),
    );
  }

  group('receiving a photo', () {
    test('downloads, verifies, decrypts and caches only ciphertext', () async {
      final att = await received();
      final progress = <double>[];
      final plain = await media.plaintext(
        conv,
        att,
        BlobRole.thumb,
        onProgress: progress.add,
      );
      expect(plain, thumbJpeg);
      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      expect(cloud.calls, [
        'url ${att.thumb.blobId}',
        'download ${att.thumb.blobId}',
      ]);

      final file = File('${cache.root.path}/${keyOf(att, BlobRole.thumb)}');
      expect(file.existsSync(), isTrue);
      final onDisk = file.readAsBytesSync();
      expect(onDisk, cloud.objects[att.thumb.blobId]);
      // No plaintext on disk: the JPEG header and body are not in the file.
      expect(onDisk.sublist(0, 4), isNot(thumbJpeg.sublist(0, 4)));
      for (final f in cache.root.listSync()) {
        expect(f.path, isNot(endsWith('.part')));
      }
    });

    test('a second open comes from the cache without the network', () async {
      final att = await received();
      await media.plaintext(conv, att, BlobRole.full);
      cloud.calls.clear();
      expect(await media.plaintext(conv, att, BlobRole.full), fullJpeg);
      expect(cloud.calls, isEmpty);
    });

    test('concurrent bubbles share one download', () async {
      final att = await received();
      final results = await Future.wait([
        media.plaintext(conv, att, BlobRole.thumb),
        media.plaintext(conv, att, BlobRole.thumb),
        media.plaintext(conv, att, BlobRole.thumb),
      ]);
      expect(results.every((r) => r.length == thumbJpeg.length), isTrue);
      expect(cloud.count('download'), 1);
    });

    test('a hash mismatch is refused before decrypting or caching', () async {
      final att = await received();
      final bad = Uint8List.fromList(cloud.objects[att.thumb.blobId]!)
        ..[3] ^= 1;
      cloud.tampered[att.thumb.blobId!] = bad;
      await expectLater(
        media.plaintext(conv, att, BlobRole.thumb),
        throwsA(
          isA<ChatMediaFailure>().having(
            (e) => e.problem,
            'problem',
            MediaProblem.corrupt,
          ),
        ),
      );
      expect(await cache.has(keyOf(att, BlobRole.thumb)), isFalse);
    });

    test('a hash that matches but does not decrypt is damaged, not cached', () async {
      final att = await received();
      // The right bytes under another key (the descriptor lies about the key).
      final wrongKey = ChatAttachment(
        key: Uint8List(32)..fillRange(0, 32, 99),
        salt: att.salt,
        mime: att.mime,
        chunk: att.chunk,
        full: att.full,
        thumb: att.thumb,
        preview: att.preview,
      );
      await expectLater(
        media.plaintext(conv, wrongKey, BlobRole.thumb),
        throwsA(
          isA<ChatMediaFailure>().having(
            (e) => e.problem,
            'problem',
            MediaProblem.corrupt,
          ),
        ),
      );
      expect(await cache.has(keyOf(att, BlobRole.thumb)), isFalse);
    });

    test(
      'a descriptor bound to another conversation does not decrypt',
      () async {
        final att = await received();
        await expectLater(
          media.plaintext(
            '00000000-0000-4000-8000-0000000000c2',
            att,
            BlobRole.thumb,
          ),
          throwsA(isA<ChatMediaFailure>()),
        );
      },
    );

    test(
      'a server size that disagrees with the descriptor is refused',
      () async {
        final att = await received();
        final lying = ChatAttachment(
          key: att.key,
          salt: att.salt,
          mime: att.mime,
          chunk: att.chunk,
          full: att.full,
          thumb: BlobPart(
            blobId: att.thumb.blobId,
            w: att.thumb.w,
            h: att.thumb.h,
            plainLen: att.thumb.plainLen,
            ctSize: att.thumb.ctSize + 16,
            ctSha256: att.thumb.ctSha256,
          ),
          preview: att.preview,
        );
        await expectLater(
          media.plaintext(conv, lying, BlobRole.thumb),
          throwsA(
            isA<ChatMediaFailure>().having(
              (e) => e.problem,
              'problem',
              MediaProblem.corrupt,
            ),
          ),
        );
        expect(cloud.count('download'), 0);
      },
    );

    for (final (name, arrange, expected)
        in <(String, void Function(ChatAttachment), MediaProblem)>[
          (
            'an expired blob',
            (a) => cloud.expired.add(a.thumb.blobId!),
            MediaProblem.unavailable,
          ),
          (
            'a blob the server no longer has',
            (a) => cloud.slots[a.thumb.blobId]!.deleted = true,
            MediaProblem.unavailable,
          ),
          (
            'an offline link request',
            (a) =>
                cloud.failNext('url', const ChatFailure('NETWORK', 'offline')),
            MediaProblem.network,
          ),
          (
            'a busy relay',
            (a) => cloud.failNext(
              'url',
              const ChatFailure('RATE_LIMITED', 'slow', 429),
            ),
            MediaProblem.network,
          ),
          (
            'an interrupted download',
            (a) => cloud.failNext(
              'download',
              const ChatFailure('NETWORK', 'offline'),
            ),
            MediaProblem.network,
          ),
          (
            'a refused signed link',
            (a) => cloud.failNext(
              'download',
              const ChatFailure('STORAGE_REFUSED', 'x', 403),
            ),
            MediaProblem.network,
          ),
          (
            'storage not configured',
            (a) => cloud.failNext(
              'url',
              const ChatFailure('CHAT_MEDIA_UNAVAILABLE', 'x', 503),
            ),
            MediaProblem.network,
          ),
        ]) {
      test('$name is $expected', () async {
        final att = await received();
        arrange(att);
        await expectLater(
          media.plaintext(conv, att, BlobRole.thumb),
          throwsA(
            isA<ChatMediaFailure>().having(
              (e) => e.problem,
              'problem',
              expected,
            ),
          ),
        );
        expect(await cache.has(keyOf(att, BlobRole.thumb)), isFalse);
      });
    }

    test('a failed download can be retried and then succeeds', () async {
      final att = await received();
      cloud.failNext('download', const ChatFailure('NETWORK', 'offline'));
      await expectLater(
        media.plaintext(conv, att, BlobRole.thumb),
        throwsA(isA<ChatMediaFailure>()),
      );
      expect(await media.plaintext(conv, att, BlobRole.thumb), thumbJpeg);
    });

    test('a damaged cache file is dropped and fetched again', () async {
      final att = await received();
      await media.plaintext(conv, att, BlobRole.thumb);
      final file = File('${cache.root.path}/${keyOf(att, BlobRole.thumb)}');
      final bytes = file.readAsBytesSync()..[0] ^= 1;
      file.writeAsBytesSync(bytes);
      cloud.calls.clear();
      expect(await media.plaintext(conv, att, BlobRole.thumb), thumbJpeg);
      expect(cloud.count('download'), 1);
      expect(file.readAsBytesSync(), cloud.objects[att.thumb.blobId]);
    });

    test('a photo that is not uploaded yet cannot be fetched', () async {
      final att = (await received()).withBlobs();
      await expectLater(
        media.plaintext(conv, att, BlobRole.thumb),
        throwsA(isA<ChatMediaFailure>()),
      );
    });

    test('URLs never appear in a failure', () async {
      final att = await received();
      cloud.failNext(
        'download',
        const ChatFailure('STORAGE_REFUSED', 'x', 403),
      );
      try {
        await media.plaintext(conv, att, BlobRole.thumb);
        fail('should throw');
      } catch (e) {
        expect('$e', isNot(contains('storage.invalid')));
        expect('$e', isNot(contains('sig=')));
      }
    });

    test('downloads are limited to three at a time', () async {
      final atts = [for (var i = 0; i < 6; i++) await received()];
      cloud.calls.clear();
      var running = 0, peak = 0;
      final limited = ChatMedia(
        api: cloud,
        transport: _Counting(cloud, (delta) {
          running += delta;
          if (running > peak) peak = running;
        }),
        codec: codec,
        cache: cache,
      );
      await Future.wait([
        for (final a in atts) limited.plaintext(conv, a, BlobRole.thumb),
      ]);
      expect(peak, lessThanOrEqualTo(3));
      expect(peak, greaterThan(1));
    });
  });

  group('cache keys and what is never deleted', () {
    test('the same blob id in another conversation is another entry', () async {
      final att = await received();
      await media.plaintext(conv, att, BlobRole.thumb);
      final other = blobCacheKey(
        '5e5e0000-0000-4000-8000-0000000000ff',
        att.thumb.blobId!,
        att.thumb.ctSha256,
      );
      expect(other, isNot(keyOf(att, BlobRole.thumb)));
      expect(await cache.has(other), isFalse);
      expect(await cache.has(keyOf(att, BlobRole.thumb)), isTrue);
    });

    test('a different hash under the same blob id is another entry', () async {
      final att = await received();
      final spoofed = blobCacheKey(
        conv,
        att.thumb.blobId!,
        List<int>.filled(32, 9),
      );
      expect(spoofed, isNot(keyOf(att, BlobRole.thumb)));
    });

    test('a cached file that verifies is kept even when its descriptor will not decrypt', () async {
      final att = await received();
      await media.plaintext(conv, att, BlobRole.thumb);
      final key = keyOf(att, BlobRole.thumb);
      final before = await cache.read(key);
      // A hostile descriptor: right hash and size, a key that does not open it.
      final wrongKey = ChatAttachment(
        key: Uint8List.fromList(List.filled(32, 99)),
        salt: att.salt,
        mime: att.mime,
        chunk: att.chunk,
        full: att.full,
        thumb: att.thumb,
        preview: att.preview,
      );
      await expectLater(
        media.plaintext(conv, wrongKey, BlobRole.thumb),
        throwsA(
          isA<ChatMediaFailure>().having(
            (e) => e.problem,
            'problem',
            MediaProblem.corrupt,
          ),
        ),
      );
      expect(await cache.read(key), before);
    });
  });

  group('ciphertext cache', () {
    late ChatBlobCache small;
    String id(int n) => n.toRadixString(16).padLeft(64, '0');
    Uint8List bytes(int n) => Uint8List(n)..fillRange(0, n, 5);
    setUp(
      () =>
          small = ChatBlobCache(Directory('${dir.path}/small'), maxBytes: 250),
    );

    test('evicts the least recently used files past the limit', () async {
      await small.put(id(1), bytes(100));
      await small.put(id(2), bytes(100));
      final old = DateTime.now().subtract(const Duration(hours: 2));
      File('${small.root.path}/${id(1)}').setLastModifiedSync(old);
      File('${small.root.path}/${id(2)}')
          .setLastModifiedSync(old.add(const Duration(minutes: 1)));
      // Opening the oldest makes it the newest.
      expect(await small.read(id(1)), isNotNull);
      await small.put(id(3), bytes(100));
      expect(await small.has(id(2)), isFalse);
      expect(await small.has(id(1)), isTrue);
      expect(await small.has(id(3)), isTrue);
      expect(await small.size(), lessThanOrEqualTo(250));
    });

    test('a single oversized put leaves the folder within the limit', () async {
      await small.put(id(1), bytes(100));
      await small.put(id(2), bytes(400));
      expect(await small.size(), lessThanOrEqualTo(250));
    });

    test('delete and wipe remove files', () async {
      await small.put(id(1), bytes(10));
      await small.put(id(2), bytes(10));
      await small.delete(id(1));
      expect(await small.has(id(1)), isFalse);
      await small.deleteAll([id(2)]);
      expect(await small.size(), 0);
      await small.put(id(3), bytes(10));
      await small.wipe();
      expect(small.root.existsSync(), isFalse);
      // A wipe is safe to repeat and the cache works afterwards.
      await small.wipe();
      await small.put(id(4), bytes(10));
      expect(await small.has(id(4)), isTrue);
    });

    test('a name that is not a digest never becomes a path', () async {
      for (final bad in ['../x', 'a/b', '', 'abc', 'A' * 64, '${id(1)}.part']) {
        expect(() => small.put(bad, bytes(1)), throwsArgumentError);
        expect(() => small.read(bad), throwsArgumentError);
      }
    });

    test('adopt takes over an upload file without copying plaintext', () async {
      final source = File('${dir.path}/src.bin')..writeAsBytesSync(bytes(20));
      await small.adopt(id(7), source);
      expect(source.existsSync(), isFalse);
      expect(await small.read(id(7)), bytes(20));
    });

    test('deleting a message forgets its cached photos', () async {
      final att = await received();
      await media.plaintext(conv, att, BlobRole.thumb);
      await media.plaintext(conv, att, BlobRole.full);
      await media.forget([
        keyOf(att, BlobRole.thumb),
        keyOf(att, BlobRole.full),
      ]);
      expect(await cache.size(), 0);
    });
  });
}

/// Counts downloads in flight.
class _Counting extends FakeCloudProxy {
  final void Function(int) track;
  _Counting(super.inner, this.track);
  @override
  Future<Uint8List> download(
    String url, {
    required int maxBytes,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    track(1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    try {
      return await inner.download(
        url,
        maxBytes: maxBytes,
        onProgress: onProgress,
      );
    } finally {
      track(-1);
    }
  }
}

String newUuid4Fixed(int n) =>
    '5b6c1111-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';
