import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'chat_api.dart';
import 'chat_av.dart';
import 'chat_av_outbox.dart' show VoiceClip;
import 'chat_play_files.dart';
import 'chat_recorder.dart';

enum CaptureStage { idle, starting, recording, finishing }

enum CaptureStart { started, denied, failed }

/// Recording a voice message: the state the composer shows, and the rules. The screen starts it by holding the
/// microphone button ([begin]) or by tapping it ([begin] with `locked`), releases it to send ([finish]), and
/// slides away or taps the bin to throw it away ([cancel]). A recording stops by itself at
/// [maxLength] (five minutes) and is then handed to [onLimit]. The file the platform writes is plaintext: it
/// is read once, deleted at once, and a recording that is cancelled is deleted without being read.
class VoiceCapture extends ChangeNotifier {
  VoiceCapture({
    required this.recorder,
    required this.files,
    this.maxLength = const Duration(milliseconds: maxVoiceMs),
    this.tick = const Duration(milliseconds: 100),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final VoiceRecorder recorder;
  final PlayFiles files;
  final Duration maxLength, tick;
  final DateTime Function() _clock;

  /// Called with the finished clip when the length limit ends the recording. Failure to read it is reported
  /// through [onLimitFailed].
  void Function(VoiceClip clip)? onLimit;
  void Function(Object error)? onLimitFailed;

  CaptureStage stage = CaptureStage.idle;
  bool locked = false;
  int elapsedMs = 0;

  /// The newest loudness readings (0 to 1) for the live bars.
  final levels = <double>[];
  static const liveBars = 36;

  final _samples = <double>[];
  StreamSubscription<double>? _levelSub;
  Timer? _timer;
  File? _file;
  DateTime? _startedAt;
  bool _cancelWanted = false;

  bool get recording => stage == CaptureStage.recording;
  bool get busy => stage != CaptureStage.idle;

  /// Starts recording. [locked]: the person tapped instead of holding, so the recording goes on until they
  /// send or cancel. Returns why it did not start when it did not.
  Future<CaptureStart> begin({bool locked = false}) async {
    if (stage != CaptureStage.idle) return CaptureStart.failed;
    this.locked = locked;
    stage = CaptureStage.starting;
    _cancelWanted = false;
    notifyListeners();
    try {
      if (await recorder.permission() != MicPermission.granted) {
        _reset();
        return CaptureStart.denied;
      }
      final file = await files.reserve('m4a');
      _file = file;
      await recorder.start(file.path);
    } catch (_) {
      await files.delete(_file);
      _reset();
      return CaptureStart.failed;
    }
    if (_cancelWanted) {
      // Let go (or slid away) before the microphone was ready.
      await _discard();
      return CaptureStart.failed;
    }
    _startedAt = _clock();
    elapsedMs = 0;
    _samples.clear();
    levels.clear();
    stage = CaptureStage.recording;
    _levelSub = recorder.levels(tick).listen((v) {
      _samples.add(v);
      levels.add(v);
      if (levels.length > liveBars) levels.removeAt(0);
    }, onError: (_) {});
    _timer = Timer.periodic(tick, (_) => _onTick());
    notifyListeners();
    return CaptureStart.started;
  }

  /// The finger moved up: the recording continues without holding.
  void lock() {
    if (stage == CaptureStage.recording && !locked) {
      locked = true;
      notifyListeners();
    }
  }

  void _onTick() {
    final started = _startedAt;
    if (started == null || stage != CaptureStage.recording) return;
    elapsedMs = _clock().difference(started).inMilliseconds;
    if (elapsedMs >= maxLength.inMilliseconds) {
      unawaited(_limitReached());
    }
    notifyListeners();
  }

  Future<void> _limitReached() async {
    try {
      final clip = await finish();
      if (clip != null) onLimit?.call(clip);
    } catch (e) {
      onLimitFailed?.call(e);
    }
  }

  /// Stops and returns the clip. Null when nothing was recording. Throws [ChatFailure] `VOICE_TOO_SHORT` for
  /// under a second (the recording is thrown away) and `VOICE_UNREADABLE` when the platform left no file.
  Future<VoiceClip?> finish() async {
    if (stage == CaptureStage.starting) {
      // Released before the microphone was ready: that was a tap that meant nothing.
      _cancelWanted = true;
      return null;
    }
    if (stage != CaptureStage.recording) return null;
    stage = CaptureStage.finishing;
    notifyListeners();
    final started = _startedAt!;
    final measured = _clock().difference(started).inMilliseconds;
    await _stopTicking();
    String? path;
    try {
      path = await recorder.stop();
    } catch (_) {
      await _discard(alreadyStopped: true);
      throw const ChatFailure(
        'VOICE_UNREADABLE',
        'That recording couldn’t be saved. Try again.',
      );
    }
    final file = path == null ? _file : File(path);
    final samples = List<double>.of(_samples);
    _reset();
    final durationMs = measured.clamp(0, maxLength.inMilliseconds);
    try {
      if (file == null) {
        throw const ChatFailure(
          'VOICE_UNREADABLE',
          'That recording couldn’t be saved. Try again.',
        );
      }
      if (durationMs < minVoiceSendMs) {
        throw const ChatFailure(
          'VOICE_TOO_SHORT',
          'Hold the microphone to record, then let go to send.',
        );
      }
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } on FileSystemException {
        throw const ChatFailure(
          'VOICE_UNREADABLE',
          'That recording couldn’t be saved. Try again.',
        );
      }
      if (bytes.isEmpty) {
        throw const ChatFailure(
          'VOICE_UNREADABLE',
          'That recording couldn’t be saved. Try again.',
        );
      }
      return VoiceClip(
        bytes: bytes,
        durationMs: durationMs,
        wave: waveFromSamples(samples),
      );
    } finally {
      await files.delete(file);
    }
  }

  /// Throws the recording away.
  Future<void> cancel() async {
    if (stage == CaptureStage.starting) {
      _cancelWanted = true;
      return;
    }
    if (stage != CaptureStage.recording) return;
    stage = CaptureStage.finishing;
    notifyListeners();
    await _stopTicking();
    await _discard();
  }

  Future<void> _stopTicking() async {
    _timer?.cancel();
    _timer = null;
    await _levelSub?.cancel();
    _levelSub = null;
  }

  Future<void> _discard({bool alreadyStopped = false}) async {
    await _stopTicking();
    if (!alreadyStopped) {
      try {
        await recorder.cancel();
      } catch (_) {}
    }
    await files.delete(_file);
    _reset();
  }

  void _reset() {
    _file = null;
    _startedAt = null;
    _samples.clear();
    levels.clear();
    elapsedMs = 0;
    locked = false;
    stage = CaptureStage.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _levelSub?.cancel();
    if (stage == CaptureStage.recording) {
      unawaited(
        recorder.cancel().then((_) => files.delete(_file)).catchError((_) {}),
      );
    }
    super.dispose();
  }
}
