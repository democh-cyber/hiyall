import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Locale, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_av.dart';
import 'package:hiyall/core/chat/chat_av_outbox.dart' show VoiceClip;
import 'package:hiyall/core/chat/chat_play_files.dart';
import 'package:hiyall/core/chat/chat_reactions.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_history.dart';
import 'package:hiyall/core/chat/chat_mp4.dart';
import 'package:hiyall/core/chat/chat_prefs.dart';
import 'package:hiyall/core/chat/chat_recorder.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/chat/chat_video_prep.dart';
import 'package:hiyall/core/chat/chat_voice_capture.dart';
import 'package:hiyall/core/chat/chat_voice_player.dart';
import 'package:hiyall/core/translate/fake_translation_service.dart';
import 'package:hiyall/core/translate/speech_service.dart';
import 'package:hiyall/core/translate/translation_memory.dart';
import 'package:hiyall/core/translate/translation_service.dart';
import 'package:hiyall/features/chat_format.dart';

import 'chat_av_helpers.dart';
import 'chat_photo_helpers.dart' show conv, meId, peerId;

// ---------------------------------------------------------------- MP4

Uint8List box(String type, List<int> body, {bool large = false}) {
  final out = BytesBuilder();
  final header = large ? 16 : 8;
  final size = header + body.length;
  if (large) {
    out.add([0, 0, 0, 1]);
    out.add(type.codeUnits);
    out.add([
      0,
      0,
      0,
      0,
      (size >> 24) & 255,
      (size >> 16) & 255,
      (size >> 8) & 255,
      size & 255,
    ]);
  } else {
    out.add([
      (size >> 24) & 255,
      (size >> 16) & 255,
      (size >> 8) & 255,
      size & 255,
    ]);
    out.add(type.codeUnits);
  }
  out.add(body);
  return out.toBytes();
}

Uint8List cat(Iterable<List<int>> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// A tiny MP4: ftyp, moov (mvhd, a trak with tkhd, udta with a location, mdia with mdhd; a moov-level udta with
/// GPS and a QuickTime meta), a uuid box (XMP) and mdat.
Uint8List sampleMp4({bool large = false}) {
  List<int> times() => [
    0,
    0,
    0,
    0,
    0xde,
    0xad,
    0xbe,
    0xef,
    0xca,
    0xfe,
    0xba,
    0xbe,
  ];
  final mvhd = box('mvhd', times() + List.filled(20, 1));
  final tkhd = box('tkhd', times() + List.filled(20, 2));
  final mdhd = box('mdhd', times() + List.filled(8, 3));
  final gps = box('udta', box('©xyz', '+12.9716+077.5946/'.codeUnits));
  final trak = box(
    'trak',
    cat([
      tkhd,
      gps,
      box('mdia', cat([mdhd, box('minf', box('dinf', const []))])),
    ]),
  );
  final meta = box(
    'meta',
    cat([
      box('keys', 'com.apple.quicktime.location.ISO6709'.codeUnits),
      box('ilst', List.filled(30, 4)),
    ]),
  );
  final moov = box('moov', cat([mvhd, trak, gps, meta]), large: large);
  return cat([
    box('ftyp', 'isom'.codeUnits + [0, 0, 2, 0] + 'isomiso2mp41'.codeUnits),
    moov,
    box('uuid', List.filled(40, 7)),
    box('free', List.filled(10, 5)),
    box('mdat', List.generate(500, (i) => (i * 13) & 255)),
  ]);
}

void main() {
  group('voice descriptor', () {
    test('a valid one parses and keeps its fields', () {
      final v = VoiceAttachment.parse(voiceDescriptor());
      expect(v.durationMs, 23000);
      expect(v.wave.length, 40);
      expect(v.part.blobId, voiceId);
      expect(v.uploaded, isTrue);
      // It writes back exactly what it read.
      expect(VoiceAttachment.parse(v.toJson()).toJson(), v.toJson());
    });

    test('a bad duration, waveform, mime, key or size is refused', () {
      void bad(Map<String, dynamic> d) => expect(
        () => VoiceAttachment.parse(d),
        throwsA(isA<FormatException>()),
        reason: '$d',
      );
      bad(voiceDescriptor(dur: 0));
      bad(voiceDescriptor(dur: 199));
      bad(voiceDescriptor(dur: maxVoiceMs + 1));
      bad({...voiceDescriptor(), 'dur': '23000'});
      bad({...voiceDescriptor(), 'dur': 1.5});
      bad(voiceDescriptor(wave: ''));
      bad(voiceDescriptor(wave: base64Encode(List.filled(65, 1))));
      bad(voiceDescriptor(wave: 'not base64!'));
      bad({...voiceDescriptor(), 'wave': 5});
      bad({...voiceDescriptor(), 'mime': 'audio/mpeg'});
      bad({...voiceDescriptor(), 'mime': 'video/mp4'});
      bad({...voiceDescriptor(), 'mime': 'audio/mp4; codecs=x'});
      bad({...voiceDescriptor(), 'key': base64Encode(List.filled(31, 1))});
      bad({...voiceDescriptor(), 'v': 2});
      bad({...voiceDescriptor(), 'salt': 'not-a-uuid'});
      bad({...voiceDescriptor(), 'chunk': 5000});
      bad({...voiceDescriptor(), 'ctSize': 4001});
      bad(
        voiceDescriptor(plainLen: maxVoiceCiphertext),
      ); // padded over the 8 MiB cap
      bad({
        ...voiceDescriptor(),
        'blobs': {'voice': 'x'},
      });
      bad({...voiceDescriptor(), 'blobs': {}});
      bad({...voiceDescriptor(), 'ctSha256': base64Encode(List.filled(31, 1))});
    });

    test('the longest voice message and the cap boundary are accepted', () {
      expect(
        VoiceAttachment.parse(voiceDescriptor(dur: maxVoiceMs)).durationMs,
        maxVoiceMs,
      );
      // The biggest plaintext whose padded ciphertext is still within 8 MiB.
      var plain = maxVoiceCiphertext;
      while (ciphertextLength(plain, 65536) > maxVoiceCiphertext) {
        plain -= 1024;
      }
      expect(
        () => VoiceAttachment.parse(voiceDescriptor(plainLen: plain)),
        returnsNormally,
      );
    });

    test('an oversized descriptor is refused', () {
      expect(
        () => VoiceAttachment.parse({...voiceDescriptor(), 'junk': 'x' * 5000}),
        throwsA(isA<FormatException>()),
      );
    });

    test('the local form allows a missing blob id', () {
      final unsent = voiceDescriptor()..['blobs'] = <String, dynamic>{};
      expect(() => VoiceAttachment.parse(unsent), throwsFormatException);
      final v = VoiceAttachment.fromLocal(unsent);
      expect(v.uploaded, isFalse);
      expect(v.withBlob(voiceId).uploaded, isTrue);
    });
  });

  group('video descriptor', () {
    test('a valid one parses, portrait too', () {
      final v = VideoAttachment.parse(videoDescriptor());
      expect(v.w, 1280);
      expect(v.durationMs, 12000);
      expect(v.aspect, closeTo(16 / 9, .01));
      expect(VideoAttachment.parse(videoDescriptor(w: 720, h: 1280)).h, 1280);
      expect(VideoAttachment.parse(v.toJson()).toJson(), v.toJson());
    });

    test('limits: duration, picture size, mime, caps, repeated blobs', () {
      void bad(Map<String, dynamic> d) => expect(
        () => VideoAttachment.parse(d),
        throwsA(isA<FormatException>()),
        reason: '$d',
      );
      bad(videoDescriptor(dur: 0));
      bad(videoDescriptor(dur: maxVideoMs + 1));
      bad(videoDescriptor(w: 1920, h: 1080));
      bad(videoDescriptor(w: 1281, h: 721));
      bad(videoDescriptor(w: 0));
      bad(videoDescriptor(w: 4000, h: 10));
      bad({...videoDescriptor(), 'mime': 'video/quicktime'});
      bad({...videoDescriptor(), 'mime': 'audio/mp4'});
      bad(videoDescriptor(plainLen: maxVideoCiphertext));
      bad({...videoDescriptor(), 'thumb': 5});
      bad({
        ...videoDescriptor(),
        'thumb': {...(videoDescriptor()['thumb'] as Map), 'w': 321},
      });
      bad({
        ...videoDescriptor(),
        'thumb': {...(videoDescriptor()['thumb'] as Map), 'blob': videoId},
      });
      bad({
        ...videoDescriptor(),
        'preview': {'t': 'png', 'd': ''},
      });
      bad({
        ...videoDescriptor(),
        'preview': {
          't': 'thumbhash',
          'd': base64Encode([1, 2]),
        },
      });
    });

    test(
      'the 40 MiB cap: the largest padded ciphertext passes, one more does not',
      () {
        var plain = maxVideoCiphertext;
        while (ciphertextLength(plain, 65536) > maxVideoCiphertext) {
          plain -= 4096;
        }
        expect(
          () => VideoAttachment.parse(videoDescriptor(plainLen: plain)),
          returnsNormally,
        );
        expect(
          () => VideoAttachment.parse(
            videoDescriptor(plainLen: plain + 4 * 1024 * 1024),
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('helpers', () {
    test('clockOf rounds to the second', () {
      expect(clockOf(0), '0:00');
      expect(clockOf(7400), '0:07');
      expect(clockOf(7600), '0:08');
      expect(clockOf(83000), '1:23');
      expect(clockOf(300000), '5:00');
    });

    test('waveFromSamples makes a bounded, scaled waveform', () {
      final quiet = waveFromSamples([.05, .1, .08, .02]);
      expect(quiet.length, waveBars);
      expect(
        quiet.reduce((a, b) => a > b ? a : b),
        255,
      ); // the loudest bar is full height
      final silent = waveFromSamples([]);
      expect(silent.length, waveBars);
      expect(silent.every((b) => b == 16), isTrue);
      final long = waveFromSamples(List.generate(5000, (i) => (i % 10) / 10));
      expect(long.length, waveBars);
      expect(long.length, lessThanOrEqualTo(maxWaveBytes));
      expect(long.every((b) => b >= 16), isTrue);
    });

    test('video target size and bitrate', () {
      expect(videoTargetSize(const Size(3840, 2160)), const Size(1280, 720));
      expect(videoTargetSize(const Size(2160, 3840)), const Size(720, 1280));
      expect(videoTargetSize(const Size(640, 360)), const Size(640, 360));
      expect(videoTargetSize(const Size(1001, 563)).width % 2, 0);
      expect(videoTargetSize(const Size(1080, 1080)), const Size(720, 720));
      expect(videoTargetSize(const Size(0, 0)), const Size(0, 0));
      // A minute fits under 32 MiB at the chosen rate; a very long clip would be capped lower.
      final bps = videoBitrateFor(60);
      expect(bps, lessThanOrEqualTo(2500000));
      expect((bps + 128000) * 60 / 8, lessThan(maxVideoPlain));
    });
  });

  group('MP4 metadata scrubbing', () {
    test('GPS, meta, uuid and timestamps go; the length and the media do not change', () {
      final input = sampleMp4();
      expect(remainingMetadata(input), isNotEmpty);
      expect(input, containsAllInOrder('©xyz'.codeUnits));
      final out = scrubMp4(input);
      expect(out.length, input.length);
      expect(remainingMetadata(out), isEmpty);
      final text = latin1.decode(out);
      expect(text.contains('xyz'), isFalse);
      expect(text.contains('+12.9716'), isFalse);
      expect(text.contains('ISO6709'), isFalse);
      expect(text.contains('quicktime'), isFalse);
      // mdat is byte for byte what it was.
      final at = input.length - (8 + 500);
      expect(out.sublist(at), input.sublist(at));
      // The box layout is unchanged: same types except the blanked ones become free.
      final before = parseBoxes(
        input,
        0,
        input.length,
      ).map((b) => b.size).toList();
      final after = parseBoxes(out, 0, out.length).map((b) => b.size).toList();
      expect(after, before);
      // Creation and modification times are zero.
      final moov = parseBoxes(
        out,
        0,
        out.length,
      ).firstWhere((b) => b.type == 'moov');
      final mvhd = parseBoxes(out, moov.bodyStart, moov.end).first;
      expect(
        out.sublist(mvhd.bodyStart + 4, mvhd.bodyStart + 12),
        List.filled(8, 0),
      );
    });

    test('a 64-bit moov box and nested boxes are handled', () {
      final out = scrubMp4(sampleMp4(large: true));
      expect(remainingMetadata(out), isEmpty);
    });

    test('a clean file stays valid and scrubbing twice changes nothing', () {
      final once = scrubMp4(sampleMp4());
      expect(scrubMp4(once), once);
    });

    test('junk, truncated boxes and a file with no movie are refused', () {
      expect(
        () => scrubMp4(Uint8List.fromList(List.filled(40, 0xff))),
        throwsFormatException,
      );
      expect(
        () => scrubMp4(sampleMp4().sublist(0, 100)),
        throwsFormatException,
      );
      expect(
        () => scrubMp4(box('ftyp', 'isom'.codeUnits)),
        throwsFormatException,
      );
      expect(
        () => remainingMetadata(Uint8List.fromList([0, 0, 0, 2, 1, 2, 3, 4])),
        throwsFormatException,
      );
    });
  });

  group('payload kinds', () {
    Map<String, dynamic> body(String kind, Map<String, dynamic> att) => {
      'v': 1,
      'kind': kind,
      'text': kind == 'voice' ? voiceFallbackText : videoFallbackText,
      'messageId': '6d6d0000-0000-4000-8000-000000000001',
      'conversationId': conv,
      'senderId': peerId,
      'sentAt': '2026-10-18T10:00:00.000Z',
      'att': att,
    };
    Incoming read(Map<String, dynamic> b, {bool aux = false}) => parseIncoming(
      b,
      messageId: '6d6d0000-0000-4000-8000-000000000001',
      conversationId: conv,
      senderId: peerId,
      me: meId,
      aux: aux,
    );

    test('voice and video payloads become messages with their descriptors', () {
      final v =
          (read(body('voice', voiceDescriptor())) as IncomingMessage).message;
      expect(v.voice, isNotNull);
      expect(v.isVoice && v.isMedia && !v.isPhoto, isTrue);
      expect(v.preview, 'Voice message (0:23)');
      final d =
          (read(body('video', videoDescriptor())) as IncomingMessage).message;
      expect(d.video, isNotNull);
      expect(d.preview, 'Video (0:12)');
    });

    test(
      'a bad descriptor still shows, as unsupported, and is never decoded',
      () {
        final v = (read(
          body('voice', voiceDescriptor(dur: 0)),
        ) as IncomingMessage).message;
        expect(v.voice, isNull);
        expect(v.unsupportedKind, 'voice');
        expect(v.isVoice, isTrue);
        final d = (read(
          body('video', videoDescriptor(w: 4000, h: 3000)),
        ) as IncomingMessage).message;
        expect(d.unsupportedKind, 'video');
        final none = (read(
          {...body('voice', voiceDescriptor())}..remove('att'),
        ) as IncomingMessage).message;
        expect(none.unsupportedKind, 'voice');
      },
    );

    test('the relay binding applies to the new kinds too', () {
      final b = body('voice', voiceDescriptor())..['senderId'] = meId;
      expect(() => read(b), throwsA(isA<ChatFailure>()));
    });

    test('the aux hint cannot carry a voice message or a video', () {
      expect(
        read(body('voice', voiceDescriptor()), aux: true),
        isA<IncomingIgnored>(),
      );
      expect(
        read(body('video', videoDescriptor()), aux: true),
        isA<IncomingIgnored>(),
      );
    });

    test('they survive the local history JSON, a bad one stays marked', () {
      final v =
          (read(body('voice', voiceDescriptor())) as IncomingMessage).message;
      final back = ChatMessage.fromJson(
        jsonDecode(jsonEncode(v.toJson())) as Map<String, dynamic>,
      );
      expect(back.voice!.toLocalJson(), v.voice!.toLocalJson());
      final bad = (read(
        body('video', videoDescriptor(dur: 0)),
      ) as IncomingMessage).message;
      final badBack = ChatMessage.fromJson(
        jsonDecode(jsonEncode(bad.toJson())) as Map<String, dynamic>,
      );
      expect(badBack.unsupportedKind, 'video');
      // A damaged stored descriptor does not stop the history loading.
      final broken = v.toJson()..['voice'] = {'v': 1};
      final loaded = ChatMessage.fromJson(
        jsonDecode(jsonEncode(broken)) as Map<String, dynamic>,
      );
      expect(loaded.voice, isNull);
      expect(loaded.unsupportedKind, 'voice');
    });

    test('a quote of a voice message or a video names the kind', () {
      final v =
          (read(body('voice', voiceDescriptor())) as IncomingMessage).message;
      final reply = replyOf(v, meId)!;
      expect(reply.kind, 'voice');
      expect(reply.snippet, '');
      final parsed = ChatReply.parse(reply.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.isVoice, isTrue);
      expect(ChatReply.parse({...reply.toJson(), 'k': 'file'}), isNull);
    });
  });

  group('recording', () {
    late FakeRecorder recorder;
    late PlayFiles files;
    late DateTime now;
    late VoiceCapture capture;
    setUp(() {
      recorder = FakeRecorder();
      files = tempPlayFiles();
      now = DateTime.utc(2026, 10, 18, 9);
      capture = VoiceCapture(
        recorder: recorder,
        files: files,
        clock: () => now,
      );
    });
    tearDown(() async {
      capture.dispose();
      await files.purge();
    });

    test('hold: begin, finish after a few seconds returns the clip and deletes the file', () async {
      expect(await capture.begin(), CaptureStart.started);
      expect(capture.recording && !capture.locked, isTrue);
      recorder
        ..level(.2)
        ..level(.9)
        ..level(.4);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 4));
      final clip = (await capture.finish())!;
      expect(clip.durationMs, 4000);
      expect(clip.bytes, recorder.audio);
      expect(clip.wave.length, waveBars);
      expect(capture.stage, CaptureStage.idle);
      expect(await files.count(), 0, reason: 'the plaintext recording is gone');
    });

    test('tap: a locked recording, and lock() locks a held one', () async {
      expect(await capture.begin(locked: true), CaptureStart.started);
      expect(capture.locked, isTrue);
      await capture.cancel();
      expect(await capture.begin(), CaptureStart.started);
      expect(capture.locked, isFalse);
      capture.lock();
      expect(capture.locked, isTrue);
      await capture.cancel();
    });

    test('cancel discards without reading and deletes the file', () async {
      await capture.begin();
      await capture.cancel();
      expect(recorder.cancels, 1);
      expect(recorder.stops, 0);
      expect(capture.stage, CaptureStage.idle);
      expect(await files.count(), 0);
    });

    test('under a second is thrown away with a calm error', () async {
      await capture.begin();
      now = now.add(const Duration(milliseconds: 600));
      await expectLater(
        capture.finish(),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'VOICE_TOO_SHORT'),
        ),
      );
      expect(await files.count(), 0);
      expect(capture.stage, CaptureStage.idle);
    });

    test('a refused microphone starts nothing', () async {
      recorder.permissionAnswer = MicPermission.denied;
      expect(await capture.begin(), CaptureStart.denied);
      expect(recorder.started, isEmpty);
      expect(capture.stage, CaptureStage.idle);
    });

    test('a recorder that fails to start leaves nothing behind', () async {
      recorder.startFailure = StateError('mic busy');
      expect(await capture.begin(), CaptureStart.failed);
      expect(capture.stage, CaptureStage.idle);
      expect(await files.count(), 0);
    });

    test('a platform that wrote no file is VOICE_UNREADABLE', () async {
      recorder.writeFile = false;
      await capture.begin();
      now = now.add(const Duration(seconds: 3));
      await expectLater(
        capture.finish(),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'VOICE_UNREADABLE'),
        ),
      );
    });

    test('letting go before the microphone is ready cancels it', () async {
      recorder.startGate = Completer<void>();
      final starting = capture.begin();
      await Future<void>.delayed(Duration.zero);
      expect(capture.stage, CaptureStage.starting);
      expect(await capture.finish(), isNull);
      recorder.startGate!.complete();
      expect(await starting, CaptureStart.failed);
      expect(capture.stage, CaptureStage.idle);
      expect(await files.count(), 0);
    });

    test(
      'the length limit ends the recording by itself and hands over the clip',
      () async {
        // The real limit is five minutes; the rule is the same at 1.2 s.
        final c = VoiceCapture(
          recorder: recorder,
          files: files,
          maxLength: const Duration(milliseconds: 1200),
          tick: const Duration(milliseconds: 40),
        );
        final done = Completer<VoiceClip>();
        c.onLimit = done.complete;
        expect(await c.begin(locked: true), CaptureStart.started);
        final clip = await done.future.timeout(const Duration(seconds: 5));
        expect(clip.durationMs, inInclusiveRange(1190, 1200));
        expect(c.stage, CaptureStage.idle);
        expect(await files.count(), 0);
        c.dispose();
      },
    );
  });

  group('playback', () {
    late PlayFiles files;
    late List<FakePlayer> made;
    late VoicePlayback playback;
    Future<Uint8List> audio() async => Uint8List.fromList([1, 2, 3, 4]);
    setUp(() {
      files = tempPlayFiles();
      made = [];
      playback = VoicePlayback(
        files: files,
        makePlayer: () => FakePlayer().also(made.add),
      );
    });
    tearDown(() async {
      playback.dispose();
      await files.purge();
    });

    test(
      'plays the decrypted bytes from a private file, then deletes it',
      () async {
        await playback.toggle('a', audio);
        expect(playback.statusOf('a'), VoiceStatus.playing);
        expect(made.single.contentOfFile, [1, 2, 3, 4]);
        expect(await files.count(), 1);
        made.single.finish();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(playback.statusOf('a'), VoiceStatus.idle);
        expect(await files.count(), 0);
        expect(made.single.disposed, isTrue);
      },
    );

    test('tapping the playing message pauses it, again resumes', () async {
      await playback.toggle('a', audio);
      await playback.toggle('a', audio);
      expect(playback.statusOf('a'), VoiceStatus.paused);
      expect(made.single.isPlaying, isFalse);
      await playback.toggle('a', audio);
      expect(playback.statusOf('a'), VoiceStatus.playing);
      expect(made, hasLength(1), reason: 'no second load');
    });

    test(
      'one at a time: starting another stops the first and resets it',
      () async {
        await playback.toggle('a', audio);
        made.single.tickTo(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
        expect(playback.positionOf('a'), const Duration(seconds: 5));
        await playback.toggle('b', audio);
        expect(playback.statusOf('a'), VoiceStatus.idle);
        expect(playback.positionOf('a'), Duration.zero);
        expect(playback.statusOf('b'), VoiceStatus.playing);
        expect(made, hasLength(2));
        expect(made.first.disposed, isTrue);
        expect(
          await files.count(),
          1,
          reason: 'only the active one has a file',
        );
      },
    );

    test('speed cycles 1x, 1.5x, 2x and holds for the next message', () async {
      await playback.toggle('a', audio);
      expect(playback.speed, 1.0);
      await playback.cycleSpeed();
      expect(playback.speed, 1.5);
      await playback.cycleSpeed();
      expect(playback.speed, 2.0);
      await playback.cycleSpeed();
      expect(playback.speed, 1.0);
      await playback.cycleSpeed();
      await playback.toggle('b', audio);
      expect(made.last.speeds, [1.5]);
    });

    test(
      'the system taking the audio away (a call, headphones out) pauses',
      () async {
        await playback.toggle('a', audio);
        made.single.interrupt();
        await Future<void>.delayed(Duration.zero);
        expect(playback.statusOf('a'), VoiceStatus.paused);
        expect(made.single.isPlaying, isFalse);
      },
    );

    test('seek moves the active message only', () async {
      await playback.toggle('a', audio);
      await playback.seek('b', const Duration(seconds: 3));
      expect(made.single.seeks, isEmpty);
      await playback.seek('a', const Duration(seconds: 3));
      expect(made.single.seeks, [const Duration(seconds: 3)]);
    });

    test('a failed fetch or load is a failed state with the reason, and leaves no file', () async {
      await playback.toggle('a', () async => throw StateError('offline'));
      expect(playback.statusOf('a'), VoiceStatus.failed);
      expect(playback.error, isA<StateError>());
      expect(await files.count(), 0);
      var tries = 0;
      final failing = VoicePlayback(
        files: files,
        makePlayer: () => FakePlayer()..loadFailure = StateError('codec'),
      );
      await failing.toggle('x', () async {
        tries++;
        return Uint8List(4);
      });
      expect(failing.statusOf('x'), VoiceStatus.failed);
      expect(tries, 1);
      expect(await files.count(), 0);
      failing.dispose();
      // Tapping a failed message tries again.
      await playback.toggle('a', audio);
      expect(playback.statusOf('a'), VoiceStatus.playing);
    });

    test('stop() ends everything and deletes the file', () async {
      await playback.toggle('a', audio);
      await playback.stop();
      expect(playback.activeId, isNull);
      expect(await files.count(), 0);
    });
  });

  group('local chat choices', () {
    test(
      'auto-translate and the language are kept in the local store only',
      () async {
        final store = MemoryChatStore();
        final prefs = ChatPrefs(store, 'p');
        await prefs.setAutoTranslate('c1', true);
        await prefs.setAutoTranslate('c2', true);
        await prefs.setAutoTranslate('c1', false);
        await prefs.setTranslateTo('de');
        await prefs.acceptTranslateConsent();
        final again = await ChatPrefs(store, 'p').read();
        expect(again.autoTranslate, {'c2'});
        expect(again.translateTo, 'de');
        expect(again.translateConsent, isTrue);
        await prefs.setTranslateTo(null);
        expect((await ChatPrefs(store, 'p').read()).translateTo, isNull);
      },
    );

    test('junk in the store reads as defaults', () async {
      final store = MemoryChatStore()
        ..values['p'] = '{"to":42,"auto":[1,"ok"],"consent":"yes"}';
      final p = await ChatPrefs(store, 'p').read();
      expect(p.translateTo, isNull);
      expect(p.autoTranslate, {'ok'});
      expect(p.translateConsent, isFalse);
      store.values['p'] = 'not json';
      expect((await ChatPrefs(store, 'p').read()).autoTranslate, isEmpty);
    });
  });

  group('on-device translation service', () {
    test('needs the packs it needs, never downloads by itself', () async {
      final s = FakeTranslationService(detects: {'hola': 'es'});
      await expectLater(
        s.translate('hola', to: 'de'),
        throwsA(
          isA<TranslationException>().having(
            (e) => e.problem,
            'problem',
            TranslationProblem.packMissing,
          ),
        ),
      );
      expect(s.downloads, isEmpty);
      expect(await s.missingPacks('es', 'de'), ['es', 'de']);
      await s.downloadPack('es');
      await s.downloadPack('de');
      final r = await s.translate('hola', to: 'de');
      expect(r.text, '[de] hola');
      expect(r.from, 'es');
      expect(s.translated, ['hola']);
    });

    test(
      'English is built in; the same language is nothing to translate',
      () async {
        final s = FakeTranslationService(
          installed: {'es'},
          detects: {'hola': 'es'},
        );
        expect((await s.translate('hola', to: 'en')).to, 'en');
        await expectLater(
          s.translate('hello', to: 'en'),
          throwsA(
            isA<TranslationException>().having(
              (e) => e.problem,
              'problem',
              TranslationProblem.nothingToTranslate,
            ),
          ),
        );
        expect(await s.detectLanguage('  '), isNull);
      },
    );

    test('packs can be deleted and the language table is sound', () async {
      final s = FakeTranslationService(installed: {'es'});
      expect(await s.isInstalled('es'), isTrue);
      await s.deletePack('es');
      await s.deletePack('en');
      expect(await s.isInstalled('es'), isFalse);
      expect(await s.isInstalled('en'), isTrue);
      expect(
        translationLanguages.map((l) => l.code).toSet().length,
        translationLanguages.length,
      );
      expect(languageByCode('de')!.english, 'German');
      expect(languageByCode('xx'), isNull);
      expect(translationCodeForLocale(const Locale('pt', 'BR')), 'pt');
      expect(translationCodeForLocale(const Locale('nb')), 'no');
      expect(translationCodeForLocale(const Locale('xx')), isNull);
    });

    test('translations are kept in memory, newest last, bounded', () {
      final m = TranslationMemory(capacity: 2);
      const r = TranslationResult('x', from: 'es', to: 'en');
      m.put('a', r);
      m.put('b', r);
      expect(m.get('a'), isNotNull); // touching a makes b the oldest
      m.put('c', r);
      expect(m.get('b'), isNull);
      expect(m.length, 2);
      m.put(TranslationMemory.keyOf('c1', 'm', 'en'), r);
      m.clear(conversationId: 'c1');
      expect(m.get(TranslationMemory.keyOf('c1', 'm', 'en')), isNull);
      m.clear();
      expect(m.length, 0);
    });
  });

  group('reading aloud', () {
    test('only a voice that works on the phone is chosen', () {
      final voices = [
        {'name': 'cloud-de', 'locale': 'de-DE', 'network_required': '1'},
        {'name': 'local-de', 'locale': 'de_DE', 'network_required': '0'},
        {'name': 'en', 'locale': 'en-US', 'network_required': '0'},
      ];
      expect(DeviceSpeechService.pickOfflineVoice(voices, 'de'), {
        'name': 'local-de',
        'locale': 'de_DE',
      });
      expect(
        DeviceSpeechService.pickOfflineVoice(voices.sublist(0, 1), 'de'),
        isNull,
      );
      expect(DeviceSpeechService.pickOfflineVoice(voices, 'fr'), isNull);
      // iOS voices carry no flag and all run on the phone.
      expect(
        DeviceSpeechService.pickOfflineVoice([
          {'name': 'Anna', 'locale': 'de-DE'},
        ], 'de'),
        isNotNull,
      );
    });
  });

  group('history helpers', () {
    test('clear removes the messages, the waiting reactions and reports what to uncache', () async {
      final store = MemoryChatStore();
      final dropped = <int>[];
      final h = ChatHistory(
        store,
        (id) => 'h.$id',
        onDropped: (id, d, kept) => dropped.add(d.length + kept.length * 1000),
      );
      for (var i = 0; i < 3; i++) {
        await h.append(
          conv,
          ChatMessage(
            messageId: '6d6d0000-0000-4000-8000-00000000000$i',
            senderId: peerId,
            text: 'm$i',
            sentAt: DateTime.utc(2026, 10, 18, 9, i),
            mine: false,
          ),
        );
      }
      expect(await h.clear(conv), 3);
      expect(await h.read(conv), isEmpty);
      expect(store.values.keys.where((k) => k.startsWith('h.')), isEmpty);
      expect(dropped, [3]);
      expect(await h.clear(conv), 0);
    });

    test('the search snippet is cut around the match and the filter finds text hits', () {
      expect(
        searchSnippet(
          'see you at the café at eight tonight, bring a friend',
          'café',
          span: 24,
        ).contains('café'),
        isTrue,
      );
      expect(searchSnippet('short', 'sh'), 'short');
      final all = [
        ChatConversation('c1', 'p1', 'Niko', 'niko', null),
        ChatConversation('c2', 'p2', 'Mara', 'mara', null),
      ];
      expect(filterConversations(all, 'zzz'), isEmpty);
      expect(filterConversations(all, 'zzz', textHits: {'c2'}).single.id, 'c2');
      expect(filterConversations(all, '@niko').single.id, 'c1');
    });

    test('day labels follow the locale, English keeps day-first', () {
      final now = DateTime(2026, 10, 18, 12);
      expect(chatDayLabel(DateTime(2026, 10, 18, 1), now), 'Today');
      expect(chatDayLabel(DateTime(2026, 10, 17, 23), now), 'Yesterday');
      expect(chatDayLabel(DateTime(2026, 10, 12), now, locale: 'en'), '12 Oct');
      expect(
        chatDayLabel(DateTime(2025, 10, 12), now, locale: 'en_GB'),
        '12 Oct 2025',
      );
      // A locale without date data falls back to the English form instead of failing.
      expect(chatDayLabel(DateTime(2026, 10, 12), now, locale: 'zz'), '12 Oct');
    });
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
