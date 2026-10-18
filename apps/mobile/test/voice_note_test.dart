import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/voice.dart';

// Recording and playing a voice note for a post or a story, with no microphone, no files and no audio device.

class FakeRecorder implements NoteRecorder {
  MicAccess access = MicAccess.granted;
  bool started = false, cancelled = false;
  final stopPath = '/tmp/note.m4a';
  @override
  Future<MicAccess> permission() async => access;
  @override
  Future<void> start(String p) async => started = true;
  @override
  Future<String?> stop() async => stopPath;
  @override
  Future<void> cancel() async => cancelled = true;
  @override
  // Cancelling answers from this zone, so a widget test's fake clock can finish it.
  Stream<double> levels(Duration every) =>
      StreamController<double>(onCancel: () async {}).stream;
  @override
  Future<void> dispose() async {}
}

class FakeFiles implements NoteFiles {
  final deleted = <String>[];
  bool present = true;
  @override
  Future<bool> exists(String path) async => present;
  @override
  Future<Uint8List> read(String path) async => Uint8List.fromList([1, 2, 3]);
  @override
  Future<void> delete(String path) async => deleted.add(path);
}

class FakePlayer implements ClipPlayer {
  static final made = <FakePlayer>[];
  FakePlayer() {
    made.add(this);
  }
  bool playing = false, stopped = false;
  final _done = StreamController<void>.broadcast();
  @override
  Future<Duration?> load(ClipSource source) async => const Duration(seconds: 5);
  @override
  Future<void> play() async => playing = true;
  @override
  Future<void> pause() async => playing = false;
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> stop() async => stopped = true;
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<void> get completed => _done.stream;
  @override
  Stream<void> get interrupted => const Stream.empty();
  @override
  Future<void> dispose() async {}
  void finish() => _done.add(null);
}

void main() {
  group('NoteCapture', () {
    const tick = Duration(milliseconds: 10);
    Future<void> pause() =>
        Future<void>.delayed(const Duration(milliseconds: 40));

    test('records, shows the countdown, keeps the note and deletes it when discarded', () async {
      var now = DateTime(2026);
      final files = FakeFiles();
      final capture = NoteCapture(
        recorder: FakeRecorder(),
        newPath: () async => '/tmp/note.m4a',
        files: files,
        tick: tick,
        clock: () => now,
      );
      await capture.start();
      expect(capture.stage, NoteStage.recording);
      expect(capture.remaining, const Duration(seconds: 60));
      now = now.add(const Duration(seconds: 12));
      await pause();
      expect(capture.elapsed, const Duration(seconds: 12));
      expect(capture.remaining, const Duration(seconds: 48));
      await capture.stop();
      expect(capture.stage, NoteStage.recorded);
      expect(capture.note!.durationMs, 12000);
      await capture.discard();
      expect(files.deleted, contains('/tmp/note.m4a'));
      expect(capture.note, isNull);
      expect(capture.stage, NoteStage.idle);
      capture.dispose();
    });

    test('stops by itself at 60 seconds', () async {
      var now = DateTime(2026);
      final capture = NoteCapture(
        recorder: FakeRecorder(),
        newPath: () async => '/tmp/note.m4a',
        files: FakeFiles(),
        tick: tick,
        clock: () => now,
      );
      await capture.start();
      now = now.add(const Duration(seconds: 75));
      await pause();
      await pause();
      expect(capture.stage, NoteStage.recorded);
      expect(capture.note!.durationMs, 60000);
      capture.dispose();
    });

    test('a recording under a second is thrown away, a denied microphone is explained and cancel keeps nothing', () async {
      var now = DateTime(2026);
      final recorder = FakeRecorder();
      final files = FakeFiles();
      final capture = NoteCapture(
        recorder: recorder,
        newPath: () async => '/tmp/note.m4a',
        files: files,
        tick: tick,
        clock: () => now,
      );
      await capture.start();
      now = now.add(const Duration(milliseconds: 400));
      await capture.stop();
      expect(capture.stage, NoteStage.failed);
      expect(capture.problem, contains('too short'));
      expect(files.deleted, contains('/tmp/note.m4a'));

      recorder.access = MicAccess.denied;
      await capture.start();
      expect(capture.stage, NoteStage.denied);

      recorder.access = MicAccess.granted;
      await capture.start();
      expect(capture.stage, NoteStage.recording);
      await capture.cancel();
      expect(recorder.cancelled, isTrue);
      expect(capture.note, isNull);
      expect(capture.stage, NoteStage.idle);
      capture.dispose();
    });
  });

  group('ClipPlayback', () {
    test('plays one clip at a time and nothing starts by itself', () async {
      FakePlayer.made.clear();
      final playback = ClipPlayback(makePlayer: FakePlayer.new);
      expect(playback.activeId, isNull);
      await playback.toggle(
        'a',
        const ClipSource.url('https://cdn.test/a.m4a'),
      );
      expect(playback.isPlaying('a'), isTrue);
      await playback.toggle(
        'b',
        const ClipSource.url('https://cdn.test/b.m4a'),
      );
      expect(playback.isPlaying('b'), isTrue);
      expect(
        playback.statusOf('a'),
        ClipStatus.idle,
        reason: 'starting b stops a',
      );
      // Tapping the one that plays pauses it, and again resumes it.
      await playback.toggle(
        'b',
        const ClipSource.url('https://cdn.test/b.m4a'),
      );
      expect(playback.statusOf('b'), ClipStatus.paused);
      await playback.toggle(
        'b',
        const ClipSource.url('https://cdn.test/b.m4a'),
      );
      expect(playback.statusOf('b'), ClipStatus.playing);
      // Reaching the end resets it.
      FakePlayer.made.last.finish();
      await Future<void>.delayed(Duration.zero);
      expect(playback.activeId, isNull);
      playback.dispose();
    });

    test('refuses a clip from an insecure address', () async {
      final playback = ClipPlayback(makePlayer: FakePlayer.new);
      await playback.toggle('a', const ClipSource.url('http://cdn.test/a.m4a'));
      expect(playback.statusOf('a'), ClipStatus.failed);
      playback.dispose();
    });
  });
}
