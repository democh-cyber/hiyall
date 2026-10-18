import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'api_config.dart' show isSecureTransport;
import 'pulse7.dart' show maxVoiceSeconds;

// Voice notes on posts and stories: recording and playing, each behind an interface so every rule runs in
// widget tests without a microphone or a speaker. The real ones need a phone. The chat's voice messages have
// their own pieces (lib/core/chat); these are independent of them.

// ---- Recording ------------------------------------------------------------------------------------------

/// Whether the microphone may be used.
enum MicAccess { granted, denied }

abstract class NoteRecorder {
  /// Asks for the microphone permission when it is not decided yet (the system dialog shows the purpose text).
  Future<MicAccess> permission();

  /// Starts writing AAC in an `.m4a` file at [path].
  Future<void> start(String path);

  /// Stops and returns the path of the finished file.
  Future<String?> stop();

  /// Stops and throws the file away.
  Future<void> cancel();

  /// How loud it is, from 0 (silence) to 1, sampled while recording.
  Stream<double> levels(Duration every);

  Future<void> dispose();
}

/// [NoteRecorder] over the `record` plugin: mono AAC-LC at 64 kbit/s, about 480 KB a minute. Device-only.
class RecordNoteRecorder implements NoteRecorder {
  AudioRecorder? _recorder;
  AudioRecorder get _r => _recorder ??= AudioRecorder();

  @override
  Future<MicAccess> permission() async =>
      await _r.hasPermission() ? MicAccess.granted : MicAccess.denied;

  @override
  Future<void> start(String path) => _r.start(
    const RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 64000,
      sampleRate: 44100,
      numChannels: 1,
      noiseSuppress: true,
      echoCancel: true,
    ),
    path: path,
  );

  @override
  Future<String?> stop() => _r.stop();

  @override
  Future<void> cancel() => _r.cancel();

  @override
  Stream<double> levels(Duration every) => _r
      .onAmplitudeChanged(every)
      // dBFS, about -60 (quiet room) to 0 (clipping).
      .map((a) => ((a.current + 60) / 60).clamp(0.0, 1.0));

  @override
  Future<void> dispose() async {
    final recorder = _recorder;
    _recorder = null;
    await recorder?.dispose();
  }
}

/// The few file operations a recording needs, behind an interface so tests need no disk.
abstract class NoteFiles {
  Future<bool> exists(String path);
  Future<Uint8List> read(String path);
  Future<void> delete(String path);
}

class IoNoteFiles implements NoteFiles {
  const IoNoteFiles();
  @override
  Future<bool> exists(String path) => File(path).exists();
  @override
  Future<Uint8List> read(String path) => File(path).readAsBytes();
  @override
  Future<void> delete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The system clears its cache folder in time.
    }
  }
}

enum NoteStage {
  /// Nothing yet.
  idle,

  /// Asking for the microphone and getting it going.
  starting,
  recording,

  /// A recording is ready to listen to, re-record or use.
  recorded,

  /// The microphone is not allowed.
  denied,

  /// It could not record, or the recording was too short.
  failed,
}

/// A finished recording, still on this phone.
class RecordedNote {
  final String path;
  final int durationMs;

  /// Loudness samples (0 to 1) to draw the clip's bars.
  final List<double> wave;
  const RecordedNote(this.path, this.durationMs, this.wave);
}

/// Recording one voice note for a post or a story: the state the recorder shows, and the rules. It stops by
/// itself at [maxLength] (60 s) and keeps the recording so it can be listened to, thrown away or recorded again.
/// The file is private to the app, and it is deleted when it is discarded, replaced, uploaded or the screen
/// closes.
class NoteCapture extends ChangeNotifier {
  NoteCapture({
    required this.recorder,
    required this.newPath,
    this.files = const IoNoteFiles(),
    this.maxLength = const Duration(seconds: maxVoiceSeconds),
    this.minLength = const Duration(seconds: 1),
    this.tick = const Duration(milliseconds: 100),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NoteRecorder recorder;
  final Future<String> Function() newPath;
  final NoteFiles files;
  final Duration maxLength, minLength, tick;
  final DateTime Function() _clock;

  NoteStage stage = NoteStage.idle;

  /// Why it is in [NoteStage.failed].
  String? problem;
  Duration elapsed = Duration.zero;
  RecordedNote? note;

  /// The newest loudness readings, for the live bars.
  final levels = <double>[];
  static const liveBars = 28;

  final _samples = <double>[];
  StreamSubscription<double>? _levelSub;
  Timer? _timer;
  String? _path;
  DateTime? _startedAt;
  bool _disposed = false;

  Duration get remaining => maxLength - elapsed;
  bool get busy => stage == NoteStage.starting || stage == NoteStage.recording;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  /// Starts recording (a previous recording is thrown away first).
  Future<void> start() async {
    if (busy) return;
    await _deleteNote();
    problem = null;
    stage = NoteStage.starting;
    _emit();
    try {
      if (await recorder.permission() != MicAccess.granted) {
        stage = NoteStage.denied;
        _emit();
        return;
      }
      _path = await newPath();
      await recorder.start(_path!);
    } catch (_) {
      await _deleteFile(_path);
      _path = null;
      stage = NoteStage.failed;
      problem = 'The microphone didn’t start. Try again.';
      _emit();
      return;
    }
    if (_disposed) {
      await _abandon();
      return;
    }
    _startedAt = _clock();
    elapsed = Duration.zero;
    _samples.clear();
    levels.clear();
    stage = NoteStage.recording;
    _levelSub = recorder.levels(tick).listen((v) {
      _samples.add(v);
      levels.add(v);
      if (levels.length > liveBars) levels.removeAt(0);
    }, onError: (_) {});
    _timer = Timer.periodic(tick, (_) => _onTick());
    _emit();
  }

  void _onTick() {
    final started = _startedAt;
    if (started == null || stage != NoteStage.recording) return;
    elapsed = _clock().difference(started);
    if (elapsed >= maxLength) {
      elapsed = maxLength;
      unawaited(stop());
    }
    _emit();
  }

  /// Ends the recording and keeps it. A recording under [minLength] is thrown away.
  Future<void> stop() async {
    if (stage != NoteStage.recording) return;
    final started = _startedAt!;
    final measured = _clock().difference(started);
    stage = NoteStage.starting; // busy while the file is closed
    _emit();
    await _stopTicking();
    String? path;
    try {
      path = await recorder.stop();
    } catch (_) {
      path = null;
    }
    path ??= _path;
    final samples = List<double>.of(_samples);
    _samples.clear();
    levels.clear();
    final length = measured > maxLength ? maxLength : measured;
    if (path == null || !await files.exists(path)) {
      await _deleteFile(_path);
      _path = null;
      stage = NoteStage.failed;
      problem = 'That recording couldn’t be saved. Try again.';
      _emit();
      return;
    }
    if (length < minLength) {
      await _deleteFile(path);
      _path = null;
      stage = NoteStage.failed;
      problem = 'That was too short. Record at least a second.';
      _emit();
      return;
    }
    _path = path;
    elapsed = length;
    note = RecordedNote(path, length.inMilliseconds, _resample(samples, 40));
    stage = NoteStage.recorded;
    _emit();
  }

  /// Stops a recording in progress and throws it away.
  Future<void> cancel() async {
    if (stage == NoteStage.recording) {
      await _stopTicking();
      try {
        await recorder.cancel();
      } catch (_) {}
      await _deleteFile(_path);
      _path = null;
      _reset();
    } else if (stage == NoteStage.recorded) {
      await discard();
    }
  }

  /// Throws a finished recording away.
  Future<void> discard() async {
    await _deleteNote();
    _reset();
  }

  /// The recording's bytes, for the upload.
  Future<Uint8List> bytes() => files.read(note!.path);

  /// Removes the file once it is uploaded (or no longer wanted); the state returns to idle.
  Future<void> consumed() => discard();

  Future<void> _deleteNote() async {
    final path = note?.path ?? _path;
    note = null;
    _path = null;
    await _deleteFile(path);
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null) return;
    await files.delete(path);
  }

  Future<void> _stopTicking() async {
    _timer?.cancel();
    _timer = null;
    await _levelSub?.cancel();
    _levelSub = null;
  }

  void _reset() {
    _startedAt = null;
    _samples.clear();
    levels.clear();
    elapsed = Duration.zero;
    problem = null;
    stage = NoteStage.idle;
    _emit();
  }

  Future<void> _abandon() async {
    try {
      await recorder.cancel();
    } catch (_) {}
    await _deleteFile(_path);
    _path = null;
  }

  /// [samples] spread over [bars] bars (the loudest reading of each slice), so a short and a long clip both
  /// fill the same width.
  static List<double> _resample(List<double> samples, int bars) {
    if (samples.isEmpty) return List<double>.filled(bars, .2);
    return [
      for (var i = 0; i < bars; i++)
        () {
          final from = (i * samples.length / bars).floor();
          final to = ((i + 1) * samples.length / bars).ceil().clamp(
            from + 1,
            samples.length,
          );
          var peak = 0.0;
          for (var j = from; j < to; j++) {
            if (samples[j] > peak) peak = samples[j];
          }
          return peak.clamp(.08, 1.0);
        }(),
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _levelSub?.cancel();
    if (stage == NoteStage.recording || stage == NoteStage.starting) {
      unawaited(
        recorder.cancel().then((_) => _deleteFile(_path)).catchError((_) {}),
      );
    } else {
      unawaited(_deleteFile(note?.path ?? _path));
    }
    super.dispose();
  }
}

// ---- Playing --------------------------------------------------------------------------------------------

/// Where a clip is played from: a signed address (a post or story) or a file on this phone (a recording that
/// is being listened to before it is posted).
class ClipSource {
  final String? url, path;
  const ClipSource.url(String this.url) : path = null;
  const ClipSource.file(String this.path) : url = null;
}

abstract class ClipPlayer {
  /// Loads [source] and returns its length when the player knows it.
  Future<Duration?> load(ClipSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> stop();
  Stream<Duration> get position;

  /// Fires when the audio reaches its end.
  Stream<void> get completed;

  /// Fires when the system takes the audio away (a call, another app, headphones coming out).
  Stream<void> get interrupted;
  Future<void> dispose();
}

/// [ClipPlayer] over `just_audio`, with the audio session set for speech. Device-only.
class JustAudioClipPlayer implements ClipPlayer {
  JustAudioClipPlayer() {
    unawaited(_configure());
  }

  final AudioPlayer _player = AudioPlayer();
  final _interrupted = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];

  Future<void> _configure() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      _subs.add(
        session.interruptionEventStream.listen((event) {
          if (event.begin) _interrupted.add(null);
        }),
      );
      _subs.add(
        session.becomingNoisyEventStream.listen((_) => _interrupted.add(null)),
      );
    } catch (_) {
      // Without a session it still plays; it just does not hear interruptions.
    }
  }

  @override
  Future<Duration?> load(ClipSource source) => source.url != null
      ? _player.setUrl(source.url!)
      : _player.setFilePath(source.path!);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration to) => _player.seek(to);
  @override
  Future<void> stop() => _player.stop();
  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<void> get completed => _player.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});
  @override
  Stream<void> get interrupted => _interrupted.stream;

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _interrupted.close();
    await _player.dispose();
  }
}

enum ClipStatus { idle, loading, playing, paused, failed }

/// Plays one clip at a time across the whole app. Starting another stops the first (its position resets),
/// tapping the one that plays pauses it, the system taking the audio away pauses it, and reaching the end
/// resets it. Nothing starts by itself: every clip waits for a tap.
class ClipPlayback extends ChangeNotifier {
  ClipPlayback({required this.makePlayer});

  final ClipPlayer Function() makePlayer;

  /// The id of the clip that is loaded, or null. Ids are unique per clip (a media id, or `draft`).
  String? activeId;
  ClipStatus status = ClipStatus.idle;
  Duration position = Duration.zero;

  ClipPlayer? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  int _epoch = 0;
  bool _disposed = false;

  ClipStatus statusOf(String id) => activeId == id ? status : ClipStatus.idle;
  Duration positionOf(String id) => activeId == id ? position : Duration.zero;
  bool isPlaying(String id) => activeId == id && status == ClipStatus.playing;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  /// Plays [id], or pauses and resumes it when it is already the active one.
  Future<void> toggle(String id, ClipSource source) async {
    if (_disposed) return;
    if (activeId == id && status != ClipStatus.failed) {
      if (status == ClipStatus.playing) {
        await _player?.pause();
        status = ClipStatus.paused;
        _emit();
      } else if (status == ClipStatus.paused) {
        await _player?.play();
        status = ClipStatus.playing;
        _emit();
      }
      return;
    }
    await _release();
    final epoch = ++_epoch;
    activeId = id;
    status = ClipStatus.loading;
    position = Duration.zero;
    _emit();
    try {
      final url = source.url;
      if (url != null && !isSecureTransport(Uri.tryParse(url))) {
        throw StateError('insecure address');
      }
      final player = _player = makePlayer();
      await player.load(source);
      if (epoch != _epoch || _disposed) return;
      _subs
        ..add(
          player.position.listen((p) {
            if (epoch != _epoch) return;
            position = p;
            _emit();
          }),
        )
        ..add(
          player.completed.listen((_) {
            if (epoch == _epoch) unawaited(_finished(epoch));
          }),
        )
        ..add(
          player.interrupted.listen((_) {
            if (epoch != _epoch || status != ClipStatus.playing) return;
            unawaited(player.pause());
            status = ClipStatus.paused;
            _emit();
          }),
        );
      status = ClipStatus.playing;
      _emit();
      unawaited(player.play());
    } catch (_) {
      if (epoch != _epoch || _disposed) return;
      await _release();
      activeId = id;
      status = ClipStatus.failed;
      _emit();
    }
  }

  Future<void> _finished(int epoch) async {
    if (epoch != _epoch) return;
    await _release();
    _emit();
  }

  /// Moves the active clip to [to].
  Future<void> seek(String id, Duration to) async {
    if (activeId != id || _player == null) return;
    position = to;
    _emit();
    await _player!.seek(to);
  }

  /// Stops whatever plays.
  Future<void> stop() async {
    _epoch++;
    await _release();
    _emit();
  }

  /// Stops [id] if it is the clip that plays or is loaded: a card scrolled away, a screen closed.
  Future<void> release(String id) async {
    if (activeId == id) await stop();
  }

  Future<void> _release() async {
    // Copied first: a second release (the screen closing while a clip stops) must not walk the same list.
    final subs = List.of(_subs);
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
    final player = _player;
    _player = null;
    activeId = null;
    status = ClipStatus.idle;
    position = Duration.zero;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
      await player.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    unawaited(_release());
    super.dispose();
  }
}

// ---- Providers ------------------------------------------------------------------------------------------

/// The microphone. The real one needs a phone.
final noteRecorderProvider = Provider<NoteRecorder>((ref) {
  final recorder = RecordNoteRecorder();
  ref.onDispose(recorder.dispose);
  return recorder;
});

final noteFilesProvider = Provider<NoteFiles>((_) => const IoNoteFiles());

/// A new private path for a recording in the app's cache folder.
final notePathProvider = Provider<Future<String> Function()>(
  (ref) => () async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/note_${DateTime.now().microsecondsSinceEpoch}.m4a';
  },
);

/// Makes the audio player. The real one needs a phone.
final clipPlayerFactoryProvider = Provider<ClipPlayer Function()>(
  (_) => JustAudioClipPlayer.new,
);

/// The one clip that plays at a time.
final clipPlaybackProvider = Provider<ClipPlayback>((ref) {
  final playback = ClipPlayback(
    makePlayer: ref.watch(clipPlayerFactoryProvider),
  );
  ref.onDispose(playback.dispose);
  return playback;
});

/// Opens this app's page in the system settings (to allow the microphone). Replaced in tests.
final appSettingsOpenerProvider = Provider<Future<void> Function()>(
  (_) => () async {
    try {
      await Geolocator.openAppSettings();
    } catch (_) {
      // Nothing more to do where the system has no such page.
    }
  },
);

/// "0:07", "1:00": a length for a clip or a countdown.
String clipTime(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
