import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_av_outbox.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_play_files.dart';
import 'package:hiyall/core/chat/chat_recorder.dart';
import 'package:hiyall/core/chat/chat_video_player.dart';
import 'package:hiyall/core/chat/chat_video_prep.dart';
import 'package:hiyall/core/chat/chat_voice_player.dart';

import 'chat_photo_helpers.dart';

/// The Rust core's role and mime pairing, on the fake codec: a role only seals its own kind of bytes.
class AvCodec extends FakeCodec {
  static const pairs = {
    'full': 'image/jpeg',
    'thumb': 'image/jpeg',
    'voice': 'audio/mp4',
    'video': 'video/mp4',
  };

  @override
  Future<SealedPart> encrypt({
    required List<int> key,
    required String role,
    required String salt,
    required String conversationId,
    required String mime,
    required int chunkSize,
    required List<int> plaintext,
  }) {
    if (pairs[role] != mime) throw Exception('role and mime do not pair');
    if (plaintext.length > 40 << 20) throw Exception('plaintext too large');
    return super.encrypt(
      key: key,
      role: role,
      salt: salt,
      conversationId: conversationId,
      mime: mime,
      chunkSize: chunkSize,
      plaintext: plaintext,
    );
  }
}

/// The blob side of the relay with the server's per-role caps (full 4 MiB, thumb 256 KiB, voice 8 MiB, video
/// 40 MiB), on top of [FakeCloud].
class AvCloud extends FakeCloud {
  static const caps = {
    'full': 4 << 20,
    'thumb': 256 << 10,
    'voice': 8 << 20,
    'video': 40 << 20,
  };

  @override
  Future<BlobSlot> createBlobSlot(
    String conversationId,
    String role,
    int sizeBytes,
    String ctSha256,
  ) async {
    final cap = caps[role];
    if (cap == null) {
      throw const ChatFailure('VALIDATION', 'bad role', 422);
    }
    if (sizeBytes > cap) {
      calls.add('slot $role');
      throw const ChatFailure('TOO_LARGE', 'That file is too large', 413);
    }
    // FakeCloud checks `full` against 4 MiB and everything else against 256 KiB: register the slot itself.
    calls.add('slot $role');
    final id =
        '5b6c0000-0000-4000-8000-${(slots.length + 1).toRadixString(16).padLeft(12, '0')}';
    slots[id] = BlobSlotRow(id, role, sizeBytes, ctSha256);
    return BlobSlot(id, 'https://storage.invalid/chat/$id?sig=secret', {
      'Content-Type': 'application/octet-stream',
      'x-amz-checksum-sha256': ctSha256,
    }, null);
  }
}

/// A recorder that writes a fixed number of bytes and reports levels you push.
class FakeRecorder implements VoiceRecorder {
  MicPermission permissionAnswer = MicPermission.granted;
  Object? startFailure;
  final started = <String>[];
  int stops = 0, cancels = 0;
  Uint8List audio = Uint8List.fromList(List.generate(2000, (i) => i & 255));
  bool writeFile = true;
  final _levels = StreamController<double>.broadcast();
  String? _path;
  Completer<void>? startGate;

  void level(double v) => _levels.add(v);

  @override
  Future<MicPermission> permission() async => permissionAnswer;

  @override
  Future<void> start(String path) async {
    await startGate?.future;
    if (startFailure != null) throw startFailure!;
    started.add(path);
    _path = path;
    if (writeFile) File(path).writeAsBytesSync(audio);
  }

  @override
  Future<String?> stop() async {
    stops++;
    return _path;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    final p = _path;
    if (p != null && File(p).existsSync()) File(p).deleteSync();
  }

  @override
  Stream<double> levels(Duration every) => _levels.stream;

  @override
  Future<void> dispose() async {}
}

/// An audio player you drive by hand.
class FakePlayer implements VoicePlayer {
  final loaded = <String>[];
  final speeds = <double>[];
  final seeks = <Duration>[];
  bool isPlaying = false, disposed = false;
  Object? loadFailure;
  final _position = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _done = StreamController<void>.broadcast();
  final _interrupted = StreamController<void>.broadcast();
  Uint8List? contentOfFile;

  void tickTo(Duration d) => _position.add(d);
  void finish() => _done.add(null);
  void interrupt() => _interrupted.add(null);

  @override
  Future<Duration?> load(File file) async {
    if (loadFailure != null) throw loadFailure!;
    loaded.add(file.path);
    contentOfFile = file.readAsBytesSync();
    return const Duration(seconds: 23);
  }

  @override
  Future<void> play() async {
    isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration to) async => seeks.add(to);
  @override
  Future<void> setSpeed(double speed) async => speeds.add(speed);
  @override
  Future<void> stop() async => isPlaying = false;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<void> get completed => _done.stream;
  @override
  Stream<void> get interrupted => _interrupted.stream;
  @override
  Future<void> dispose() async => disposed = true;
}

/// A video player that shows a coloured box.
class FakeVideoPlayer extends ChatVideoPlayer {
  File? opened;
  bool _playing = false, _ended = false, _ready = false;
  Object? openFailure;
  Duration _position = Duration.zero;

  @override
  Future<void> open(File file) async {
    if (openFailure != null) throw openFailure!;
    opened = file;
    _ready = true;
    notifyListeners();
  }

  @override
  bool get ready => _ready;
  @override
  bool get playing => _playing;
  @override
  bool get ended => _ended;
  @override
  Duration get position => _position;
  @override
  Duration get duration => const Duration(seconds: 12);

  @override
  Widget buildSurface() => const SizedBox(
    key: Key('fake-video-surface'),
    width: 160,
    height: 90,
    child: ColoredBox(color: Colors.teal),
  );

  @override
  Future<void> play() async {
    _playing = true;
    _ended = false;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration to) async {
    _position = to;
    notifyListeners();
  }

  void end() {
    _playing = false;
    _ended = true;
    notifyListeners();
  }
}

/// A video preparer that returns what it is told, and records the paths it was given.
class FakePreparer implements VideoPreparer {
  final paths = <String>[];
  Object? failure;
  Completer<void>? gate;
  PreparedVideo result = preparedVideo();

  @override
  Future<PreparedVideo> prepare(
    String sourcePath, {
    void Function(double progress)? onProgress,
  }) async {
    paths.add(sourcePath);
    onProgress?.call(.5);
    await gate?.future;
    if (failure != null) throw failure!;
    return result;
  }
}

PreparedVideo preparedVideo({int bytes = 5000, int durationMs = 12000}) =>
    PreparedVideo(
      bytes: Uint8List.fromList(List.generate(bytes, (i) => (i * 7) & 255)),
      w: 1280,
      h: 720,
      durationMs: durationMs,
      poster: fakeJpeg(320, 180, extra: 60),
      posterW: 320,
      posterH: 180,
      preview: Uint8List.fromList(List.generate(21, (i) => i + 1)),
    );

VoiceClip voiceClip({int bytes = 3000, int durationMs = 8000}) => VoiceClip(
  bytes: Uint8List.fromList(List.generate(bytes, (i) => (i * 3) & 255)),
  durationMs: durationMs,
  wave: Uint8List.fromList(List.generate(48, (i) => 20 + i * 4)),
);

const voiceId = '7a7a0000-0000-4000-8000-000000000001';
const videoId = '7a7a0000-0000-4000-8000-000000000002';
const posterId = '7a7a0000-0000-4000-8000-000000000003';

/// A valid voice descriptor as it travels in a payload.
Map<String, dynamic> voiceDescriptor({
  int dur = 23000,
  int plainLen = 4000,
  String? wave,
}) => {
  'v': 1,
  'key': base64Encode(List.generate(32, (i) => i)),
  'salt': saltId,
  'mime': 'audio/mp4',
  'chunk': 65536,
  'plainLen': plainLen,
  'ctSize': ciphertextLength(plainLen, 65536),
  'ctSha256': base64Encode(List.filled(32, 5)),
  'blobs': {'voice': voiceId},
  'dur': dur,
  'wave': wave ?? base64Encode(List.generate(40, (i) => 30 + i)),
};

/// A valid video descriptor.
Map<String, dynamic> videoDescriptor({
  int dur = 12000,
  int w = 1280,
  int h = 720,
  int plainLen = 100000,
}) => {
  'v': 1,
  'key': base64Encode(List.generate(32, (i) => i)),
  'salt': saltId,
  'mime': 'video/mp4',
  'chunk': 65536,
  'plainLen': plainLen,
  'ctSize': ciphertextLength(plainLen, 65536),
  'ctSha256': base64Encode(List.filled(32, 6)),
  'blobs': {'video': videoId},
  'w': w,
  'h': h,
  'dur': dur,
  'thumb': {
    'blob': posterId,
    'w': 320,
    'h': 180,
    'plainLen': 800,
    'ctSize': ciphertextLength(800, 65536),
    'ctSha256': base64Encode(List.filled(32, 8)),
  },
  'preview': {'t': 'thumbhash', 'd': base64Encode(List.filled(21, 3))},
};

/// A temporary folder for [PlayFiles].
PlayFiles tempPlayFiles() => PlayFiles(
  Directory.systemTemp
      .createTempSync('hiyall_play')
      .childDirectory('chat_play'),
);

extension on Directory {
  Directory childDirectory(String name) => Directory('$path/$name');
}
