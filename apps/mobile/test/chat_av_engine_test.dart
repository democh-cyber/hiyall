import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_av.dart';
import 'package:hiyall/core/chat/chat_av_outbox.dart';
import 'package:hiyall/core/chat/chat_blob_transport.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_media.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_av_helpers.dart';
import 'chat_photo_helpers.dart' show FakeCloud, conv, meId, peerId;
import 'chat_reactions_engine_test.dart' show MemoryRelay, RelayApi;

/// The relay of two devices with the blob routes: one shared object store, the server's claim rules for
/// `blobIds` and an "attachments allowed" switch (the peer-replied-or-friends gate).
class AvRelayApi extends RelayApi {
  AvRelayApi(super.relay, super.user, this.cloud);
  final AvCloud cloud;
  static bool allowed = true;
  static final claimedBy = <String, List<String>>{};
  static final hidden = <String>[];
  static final pins = <String, bool>{};
  static List<Map<String, dynamic>> hiddenItems = [];
  static List<String> closedIds = [];

  @override
  Future<BlobSlot> createBlobSlot(
    String conversationId,
    String role,
    int sizeBytes,
    String ctSha256,
  ) async {
    if (!allowed) {
      throw const ChatFailure(
        'ATTACHMENTS_NOT_ALLOWED',
        'You can send photos once they reply',
        403,
      );
    }
    return cloud.createBlobSlot(conversationId, role, sizeBytes, ctSha256);
  }

  @override
  Future<void> completeBlob(String blobId) => cloud.completeBlob(blobId);
  @override
  Future<void> deleteBlob(String blobId) => cloud.deleteBlob(blobId);
  @override
  Future<({String url, int? sizeBytes})> blobDownloadUrl(
    String conversationId,
    String blobId,
  ) => cloud.blobDownloadUrl(conversationId, blobId);

  @override
  Future<DateTime?> send(
    String conversationId,
    Map<String, dynamic> message, {
    List<String> blobIds = const [],
    bool aux = false,
  }) async {
    final id = message['messageId'] as String;
    if (!claimedBy.containsKey(id)) {
      for (final b in blobIds) {
        final s = cloud.slots[b];
        if (s == null ||
            s.deleted ||
            !s.completed ||
            cloud.claimed.contains(b)) {
          throw const ChatFailure('BLOB_NOT_READY', 'Finish uploading', 409);
        }
      }
      cloud.claimed.addAll(blobIds);
      claimedBy[id] = blobIds;
    }
    return super.send(conversationId, message, blobIds: blobIds, aux: aux);
  }

  @override
  Future<void> pinConversation(String id, bool pinned) async {
    if (pinned && pins.values.where((v) => v).length >= 5) {
      throw const ChatFailure('PIN_LIMIT', 'You can pin up to 5 chats', 409);
    }
    pins[id] = pinned;
  }

  @override
  Future<void> hideConversation(String id) async => hidden.add(id);

  @override
  Future<({List<Map<String, dynamic>> items, List<String> closedIds})>
  hiddenConversations() async => (items: hiddenItems, closedIds: closedIds);
}

final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';

String? _coreMissing() {
  if (File(_corePath).existsSync()) return null;
  if (Platform.environment['REQUIRE_RUST_CORE'] == '1') {
    throw StateError('REQUIRE_RUST_CORE=1 but $_corePath is missing');
  }
  return 'the debug Rust core is not built (cargo build in apps/mobile/rust)';
}

void main() {
  group('voice and video over the real Olm core', skip: _coreMissing(), () {
    setUpAll(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(_corePath));
    });

    var tick = 0;
    late MemoryRelay relay;
    late AvCloud cloud;
    late ChatEngine alice, bob;
    late Directory aliceRoot, bobRoot;

    Future<ChatEngine> device(String user, Directory root) async {
      final e = ChatEngine(
        userId: user,
        api: AvRelayApi(relay, user, cloud),
        store: MemoryChatStore(),
        platform: 'test',
        codec: AvCodec(),
        transport: _Transport(cloud),
        mediaRoot: root,
        reactionRetryDelays: const [Duration.zero],
        clock: () => DateTime.utc(2026, 10, 18, 12, 0, 0, 0, tick++ * 10),
      );
      await e.start(poll: Duration.zero);
      return e;
    }

    Future<ChatMessage> settled(ChatEngine e, String id) async {
      for (var i = 0; i < 400; i++) {
        final m = (await e.history(conv))
            .where((m) => m.messageId == id)
            .firstOrNull;
        if (m != null && m.status != SendStatus.sending) return m;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('message $id did not settle');
    }

    setUp(() async {
      AvRelayApi.allowed = true;
      AvRelayApi.claimedBy.clear();
      AvRelayApi.hidden.clear();
      AvRelayApi.pins.clear();
      AvRelayApi.hiddenItems = [];
      AvRelayApi.closedIds = [];
      relay = MemoryRelay();
      cloud = AvCloud();
      aliceRoot = Directory.systemTemp.createTempSync('hiyall_av_alice');
      bobRoot = Directory.systemTemp.createTempSync('hiyall_av_bob');
      alice = await device(meId, aliceRoot);
      bob = await device(peerId, bobRoot);
    });
    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
      aliceRoot.deleteSync(recursive: true);
      bobRoot.deleteSync(recursive: true);
    });

    test(
      'a voice message goes out as one voice blob and the peer opens it',
      () async {
        final clip = voiceClip(bytes: 5000, durationMs: 9000);
        final sent = await alice.sendVoice(conv, peerId, clip);
        expect(sent.status, SendStatus.sending);
        final done = await settled(alice, sent.messageId);
        expect(done.status, SendStatus.sent);
        expect(done.voice!.uploaded, isTrue);
        // One blob, the voice role, exactly the ciphertext length; nothing about the kind is on the wire.
        expect(cloud.live.map((s) => s.role), ['voice']);
        expect(AvRelayApi.claimedBy[sent.messageId], hasLength(1));
        expect(relay.wire.last['aux'], isFalse);

        await bob.pollNow();
        final got = (await bob.history(conv)).single;
        expect(got.voice, isNotNull);
        expect(got.text, voiceFallbackText);
        expect(got.voice!.durationMs, 9000);
        expect(got.voice!.wave, clip.wave);
        final plain = await bob.media!.plaintextBlob(conv, got.voice!.spec);
        expect(plain, clip.bytes);
        // The sender plays its own message from the cache, with no download.
        final before = cloud.count('url');
        expect(
          await alice.media!.plaintextBlob(conv, done.voice!.spec),
          clip.bytes,
        );
        expect(cloud.count('url'), before);
      },
    );

    test(
      'a video goes out as a poster and a video blob, in that order',
      () async {
        final video = preparedVideo(bytes: 9000, durationMs: 15000);
        final sent = await alice.sendVideo(conv, peerId, video);
        final done = await settled(alice, sent.messageId);
        expect(done.video!.uploaded, isTrue);
        expect(cloud.calls.where((c) => c.startsWith('slot')), [
          'slot thumb',
          'slot video',
        ]);
        expect(AvRelayApi.claimedBy[sent.messageId], hasLength(2));
        expect(alice.localPoster(sent.messageId), video.poster);

        await bob.pollNow();
        final got = (await bob.history(conv)).single;
        expect(got.video!.durationMs, 15000);
        expect(got.text, videoFallbackText);
        expect(got.video!.w, 1280);
        expect(
          await bob.media!.plaintextBlob(conv, got.video!.videoSpec),
          video.bytes,
        );
        expect(
          await bob.media!.plaintextBlob(conv, got.video!.posterSpec),
          video.poster,
        );
      },
    );

    test(
      'a ciphertext that does not match its hash is never decrypted or cached',
      () async {
        final sent = await alice.sendVoice(conv, peerId, voiceClip());
        await settled(alice, sent.messageId);
        await bob.pollNow();
        final got = (await bob.history(conv)).single.voice!;
        final id = got.part.blobId!;
        final bad = Uint8List.fromList(cloud.objects[id]!)..[3] ^= 1;
        cloud.tampered[id] = bad;
        await expectLater(
          bob.media!.plaintextBlob(conv, got.spec),
          throwsA(
            isA<ChatMediaFailure>().having(
              (e) => e.problem,
              'problem',
              MediaProblem.corrupt,
            ),
          ),
        );
        expect(_ls('${bobRoot.path}/chat_blobs'), isEmpty);
      },
    );

    test('an expired blob is "unavailable", offline is "network"', () async {
      final sent = await alice.sendVoice(conv, peerId, voiceClip());
      await settled(alice, sent.messageId);
      await bob.pollNow();
      final got = (await bob.history(conv)).single.voice!;
      cloud.expired.add(got.part.blobId!);
      await expectLater(
        bob.media!.plaintextBlob(conv, got.spec),
        throwsA(
          isA<ChatMediaFailure>().having(
            (e) => e.problem,
            'problem',
            MediaProblem.unavailable,
          ),
        ),
      );
      cloud.expired.clear();
      cloud.failNext('url', const ChatFailure('NETWORK', 'offline'));
      await expectLater(
        bob.media!.plaintextBlob(conv, got.spec),
        throwsA(
          isA<ChatMediaFailure>().having(
            (e) => e.problem,
            'problem',
            MediaProblem.network,
          ),
        ),
      );
    });

    test('the sender refuses a bad duration, waveform, size or length before anything is stored', () async {
      Future<void> refuses(Future<Object?> Function() send, String code) async {
        await expectLater(
          send(),
          throwsA(isA<ChatFailure>().having((e) => e.code, 'code', code)),
        );
        expect(await alice.history(conv), isEmpty);
        expect(cloud.calls, isEmpty);
      }

      await refuses(
        () => alice.sendVoice(conv, peerId, voiceClip(durationMs: 999)),
        'VOICE_LENGTH',
      );
      await refuses(
        () => alice.sendVoice(
          conv,
          peerId,
          voiceClip(durationMs: maxVoiceMs + 1),
        ),
        'VOICE_LENGTH',
      );
      await refuses(
        () => alice.sendVoice(
          conv,
          peerId,
          VoiceClip(
            bytes: Uint8List(100),
            durationMs: 5000,
            wave: Uint8List(65),
          ),
        ),
        'VOICE_UNREADABLE',
      );
      await refuses(
        () => alice.sendVoice(
          conv,
          peerId,
          VoiceClip(
            bytes: Uint8List(100),
            durationMs: 5000,
            wave: Uint8List(0),
          ),
        ),
        'VOICE_UNREADABLE',
      );
      await refuses(
        () => alice.sendVoice(
          conv,
          peerId,
          voiceClip(bytes: maxVoiceCiphertext + 1),
        ),
        'VOICE_TOO_LARGE',
      );
      await refuses(
        () => alice.sendVideo(
          conv,
          peerId,
          preparedVideo(durationMs: maxVideoMs + 1),
        ),
        'VIDEO_LENGTH',
      );
      await refuses(
        () => alice.sendVideo(conv, peerId, preparedVideo(durationMs: 50)),
        'VIDEO_LENGTH',
      );
      await refuses(
        () => alice.sendVideo(
          conv,
          peerId,
          preparedVideo(bytes: maxVideoPlain + 1),
        ),
        'VIDEO_TOO_LARGE',
      );
    });

    test('the largest video the sender produces fits the 40 MiB server cap after padding', () async {
      final padded = ciphertextLength(maxVideoPlain, attachmentChunk);
      expect(padded, lessThan(maxVideoCiphertext));
      expect(padded - maxVideoPlain, lessThan(maxVideoPlain * .06));
      // And the fake relay enforces the server caps per role.
      await expectLater(
        cloud.createBlobSlot(conv, 'video', maxVideoCiphertext + 1, 'x'),
        throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'TOO_LARGE')),
      );
      expect(
        (await cloud.createBlobSlot(
          conv,
          'video',
          maxVideoCiphertext,
          'x',
        )).blobId,
        isNotEmpty,
      );
      await expectLater(
        cloud.createBlobSlot(conv, 'voice', maxVoiceCiphertext + 1, 'x'),
        throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'TOO_LARGE')),
      );
    });

    test('a failed upload keeps the message, retries with the same id and never duplicates', () async {
      cloud.failNext('upload', const ChatFailure('NETWORK', 'offline'));
      final sent = await alice.sendVoice(conv, peerId, voiceClip());
      final failed = await settled(alice, sent.messageId);
      expect(failed.status, SendStatus.failed);
      expect(failed.failure, 'NETWORK');
      await alice.retryAv(conv, sent.messageId);
      final done = await settled(alice, sent.messageId);
      expect(done.status, SendStatus.sent);
      await bob.pollNow();
      expect(await bob.history(conv), hasLength(1));
      expect((await alice.history(conv)), hasLength(1));
    });

    test('before the peer has replied the send fails with the reason and the recording is kept for a retry', () async {
      AvRelayApi.allowed = false;
      final sent = await alice.sendVoice(conv, peerId, voiceClip());
      final failed = await settled(alice, sent.messageId);
      expect(failed.status, SendStatus.failed);
      expect(failed.failure, 'ATTACHMENTS_NOT_ALLOWED');
      AvRelayApi.allowed = true;
      await alice.retryAv(conv, sent.messageId);
      expect((await settled(alice, sent.messageId)).status, SendStatus.sent);
    });

    test(
      'a failed voice message can be deleted; its files and slots go with it',
      () async {
        cloud.failNext('complete', const ChatFailure('NETWORK', 'offline'));
        final sent = await alice.sendVoice(conv, peerId, voiceClip());
        await settled(alice, sent.messageId);
        await alice.discardAv(conv, sent.messageId);
        expect(await alice.history(conv), isEmpty);
        expect(
          Directory('${aliceRoot.path}/chat_outbox/av').existsSync()
              ? Directory('${aliceRoot.path}/chat_outbox/av').listSync()
              : [],
          isEmpty,
        );
        expect(cloud.live, isEmpty);
      },
    );

    test('a reply can quote a voice message', () async {
      final sent = await alice.sendVoice(conv, peerId, voiceClip());
      await settled(alice, sent.messageId);
      await bob.pollNow();
      final theirs = (await bob.history(conv)).single;
      await bob.send(conv, meId, 'nice one', replyTo: theirs);
      await alice.pollNow();
      final reply = (await alice.history(conv)).last;
      expect(reply.reply!.kind, 'voice');
      expect(reply.reply!.snippet, '');
    });

    test('searching the history reads text and captions on this phone, never voice or video', () async {
      await alice.send(conv, peerId, 'meet at the café at eight');
      final v = await alice.sendVoice(conv, peerId, voiceClip());
      await settled(alice, v.messageId);
      final hits = await alice.searchHistory('CAFÉ', [conv, 'other']);
      expect(hits.keys, [conv]);
      expect(hits[conv]!.count, 1);
      expect(hits[conv]!.newest.text, contains('café'));
      expect(await alice.searchHistory('voice message', [conv]), isEmpty);
      expect(await alice.searchHistory('  ', [conv]), isEmpty);
    });

    test('clear history wipes this phone only: messages, cached files, unsent uploads', () async {
      final sent = await alice.sendVideo(conv, peerId, preparedVideo());
      await settled(alice, sent.messageId);
      await alice.send(conv, peerId, 'hello');
      expect(_ls('${aliceRoot.path}/chat_blobs'), isNotEmpty);
      await alice.clearHistory(conv);
      expect(await alice.history(conv), isEmpty);
      for (
        var i = 0;
        i < 100 && _ls('${aliceRoot.path}/chat_blobs').isNotEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(_ls('${aliceRoot.path}/chat_blobs'), isEmpty);
      // The peer keeps theirs and new messages still arrive.
      await bob.pollNow();
      expect(await bob.history(conv), hasLength(2));
      await bob.send(conv, meId, 'still here');
      await alice.pollNow();
      expect((await alice.history(conv)).single.text, 'still here');
    });

    test('the Deleted chats list wipes chats the relay says are closed, and expired ones', () async {
      await alice.send(conv, peerId, 'one');
      const other = '5e5e0000-0000-4000-8000-0000000000aa';
      await alice.send(other, peerId, 'two');
      const stale = '5e5e0000-0000-4000-8000-0000000000bb';
      await alice.send(stale, peerId, 'three');
      AvRelayApi.closedIds = [conv];
      AvRelayApi.hiddenItems = [
        {
          'conversationId': stale,
          'peer': {'userId': peerId, 'displayName': 'Niko', 'username': 'niko'},
          'hiddenAt': '2026-09-01T00:00:00Z',
          // The 30 days ended before this phone's "now" (October 18).
          'restoreUntil': '2026-10-01T00:00:00Z',
        },
        {
          'conversationId': other,
          'peer': {'userId': peerId, 'displayName': 'Niko', 'username': 'niko'},
          'hiddenAt': '2026-10-10T00:00:00Z',
          'restoreUntil': '2026-11-09T00:00:00Z',
        },
      ];
      final listed = await alice.hiddenConversations();
      expect(listed.map((c) => c.id), [other]);
      expect(listed.single.restoreUntil, isNotNull);
      expect(await alice.history(conv), isEmpty);
      expect(await alice.history(stale), isEmpty);
      expect((await alice.history(other)).single.text, 'two');
    });

    test(
      'pin and delete go to the relay, the pin limit is its answer',
      () async {
        for (var i = 0; i < 5; i++) {
          await alice.pinConversation('c$i', true);
        }
        await expectLater(
          alice.pinConversation('c5', true),
          throwsA(
            isA<ChatFailure>().having((e) => e.code, 'code', 'PIN_LIMIT'),
          ),
        );
        await alice.pinConversation('c0', false);
        await alice.pinConversation('c5', true);
        await alice.hideConversation(conv);
        expect(AvRelayApi.hidden, [conv]);
        // Deleting a chat keeps this phone's history for the 30 days it can be restored.
        await alice.send(conv, peerId, 'kept');
        await alice.hideConversation(conv);
        expect((await alice.history(conv)).single.text, 'kept');
      },
    );

    test('the start sweeps leftover plaintext and sign-out removes the play folder', () async {
      final leftover = File('${aliceRoot.path}/chat_play/old.m4a');
      leftover.createSync(recursive: true);
      leftover.writeAsBytesSync([1, 2, 3]);
      final again = await device(meId, aliceRoot);
      expect(leftover.existsSync(), isFalse);
      Directory('${aliceRoot.path}/chat_play').createSync(recursive: true);
      File('${aliceRoot.path}/chat_play/x.mp4').writeAsBytesSync([1]);
      await ChatLocalData.wipeFiles(aliceRoot);
      expect(Directory('${aliceRoot.path}/chat_play').existsSync(), isFalse);
      expect(ChatLocalData.folders, contains('chat_play'));
      await again.dispose();
    });

    test(
      'sign-out wipes unsent voice and video entries and their files',
      () async {
        cloud.failNext('complete', const ChatFailure('NETWORK', 'offline'));
        final sent = await alice.sendVoice(conv, peerId, voiceClip());
        await settled(alice, sent.messageId);
        expect(
          Directory('${aliceRoot.path}/chat_outbox/av/${sent.messageId}')
              .existsSync(),
          isTrue,
        );
        await alice.wipeMedia();
        expect(
          Directory('${aliceRoot.path}/chat_outbox').existsSync(),
          isFalse,
        );
        expect(_ls('${aliceRoot.path}/chat_blobs'), isEmpty);
      },
    );
  });
}

List<FileSystemEntity> _ls(String path) =>
    Directory(path).existsSync() ? Directory(path).listSync() : [];

class _Transport implements ChatBlobTransport {
  _Transport(this.cloud);
  final FakeCloud cloud;
  @override
  Future<void> upload(
    BlobSlot slot,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancel,
  }) => cloud.upload(slot, bytes, onProgress: onProgress, cancel: cancel);
  @override
  Future<Uint8List> download(
    String url, {
    required int maxBytes,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) => cloud.download(
    url,
    maxBytes: maxBytes,
    onProgress: onProgress,
    cancel: cancel,
  );
}
