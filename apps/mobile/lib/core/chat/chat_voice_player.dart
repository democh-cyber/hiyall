import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'chat_play_files.dart';

/// The audio player behind the voice bubbles, as an interface so the playback rules run in tests without a
/// phone. The real one is [JustAudioVoicePlayer].
abstract class VoicePlayer {
  /// Loads [file] and returns its length when the player knows it.
  Future<Duration?> load(File file);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> setSpeed(double speed);
  Future<void> stop();

  Stream<Duration> get position;

  /// True while sound is playing.
  Stream<bool> get playing;

  /// Fires when the audio reaches its end.
  Stream<void> get completed;

  /// Fires when the system takes the audio away (a call, another app, the headphones coming out): playback
  /// must pause and stay paused.
  Stream<void> get interrupted;
  Future<void> dispose();
}

/// [VoicePlayer] over `just_audio`, with the session set for speech so the system treats a voice message like
/// a call-length clip: other audio ducks or pauses, a phone call or a Bluetooth disconnect pauses it, and
/// headphones coming out stop it. Device-only: needs a phone's audio stack.
class JustAudioVoicePlayer implements VoicePlayer {
  JustAudioVoicePlayer() {
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
      // Without a session the player still plays; it just does not hear interruptions.
    }
  }

  @override
  Future<Duration?> load(File file) => _player.setFilePath(file.path);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration to) => _player.seek(to);
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<bool> get playing => _player.playingStream;
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

enum VoiceStatus { idle, loading, playing, paused, failed }

/// The speeds a voice message plays at, in the order the speed button cycles them.
const voiceSpeeds = [1.0, 1.5, 2.0];

/// Plays one voice message at a time. Starting another stops the first (its position resets), tapping the one
/// that plays pauses it, the system taking the audio away pauses it, and reaching the end resets it. The
/// decrypted audio is written to a private file (see [PlayFiles]) only while it is the active one, and the
/// file is deleted as soon as it stops being active.
class VoicePlayback extends ChangeNotifier {
  VoicePlayback({required this.makePlayer, required this.files});

  final VoicePlayer Function() makePlayer;
  final PlayFiles files;

  /// Message id of the active message, or null.
  String? activeId;
  VoiceStatus status = VoiceStatus.idle;
  Duration position = Duration.zero;
  double speed = 1.0;

  /// Why the active message could not be loaded or played (null otherwise).
  Object? error;

  VoicePlayer? _player;
  File? _file;
  final _subs = <StreamSubscription<dynamic>>[];
  int _epoch = 0;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool isActive(String id) => activeId == id;
  VoiceStatus statusOf(String id) => activeId == id ? status : VoiceStatus.idle;
  Duration positionOf(String id) => activeId == id ? position : Duration.zero;

  /// Plays [id], or pauses/resumes it when it is already the active one. [plaintext] fetches and decrypts the
  /// audio (only called when it has to load).
  Future<void> toggle(String id, Future<Uint8List> Function() plaintext) async {
    if (_disposed) return;
    if (activeId == id && status != VoiceStatus.failed) {
      if (status == VoiceStatus.playing) {
        await _player?.pause();
        status = VoiceStatus.paused;
        notifyListeners();
      } else if (status == VoiceStatus.paused) {
        await _player?.play();
        status = VoiceStatus.playing;
        notifyListeners();
      }
      return;
    }
    await _release();
    final epoch = ++_epoch;
    activeId = id;
    status = VoiceStatus.loading;
    position = Duration.zero;
    error = null;
    notifyListeners();
    try {
      final bytes = await plaintext();
      if (epoch != _epoch || _disposed) return;
      final file = await files.write(bytes, 'm4a');
      _file = file;
      final player = _player = makePlayer();
      await player.load(file);
      if (epoch != _epoch || _disposed) return;
      await player.setSpeed(speed);
      _subs
        ..add(
          player.position.listen((p) {
            if (epoch != _epoch) return;
            position = p;
            notifyListeners();
          }),
        )
        ..add(
          player.completed.listen((_) {
            if (epoch != _epoch) return;
            unawaited(_finished(epoch));
          }),
        )
        ..add(
          player.interrupted.listen((_) {
            if (epoch != _epoch || status != VoiceStatus.playing) return;
            unawaited(player.pause());
            status = VoiceStatus.paused;
            notifyListeners();
          }),
        );
      status = VoiceStatus.playing;
      notifyListeners();
      unawaited(player.play());
    } catch (e) {
      if (epoch != _epoch || _disposed) return;
      await _release();
      activeId = id;
      error = e;
      status = VoiceStatus.failed;
      notifyListeners();
    }
  }

  Future<void> _finished(int epoch) async {
    if (epoch != _epoch) return;
    await _release();
    notifyListeners();
  }

  /// Moves the active message to [to].
  Future<void> seek(String id, Duration to) async {
    if (activeId != id || _player == null) return;
    position = to;
    notifyListeners();
    await _player!.seek(to);
  }

  /// 1x, then 1.5x, then 2x, then 1x again. The speed holds for the next message too.
  Future<void> cycleSpeed() async {
    final next =
        voiceSpeeds[(voiceSpeeds.indexOf(speed) + 1) % voiceSpeeds.length];
    speed = next;
    notifyListeners();
    await _player?.setSpeed(next);
  }

  /// Stops whatever plays (leaving the chat, a new recording starting, sign-out).
  Future<void> stop() async {
    _epoch++;
    await _release();
    notifyListeners();
  }

  Future<void> _release() async {
    final subs = List.of(_subs);
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
    final player = _player;
    _player = null;
    activeId = null;
    error = null;
    status = VoiceStatus.idle;
    position = Duration.zero;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
      await player.dispose();
    }
    await files.delete(_file);
    _file = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    unawaited(_release());
    super.dispose();
  }
}
