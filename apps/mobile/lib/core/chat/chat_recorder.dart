import 'dart:async';

import 'package:record/record.dart';

/// Whether the microphone may be used.
enum MicPermission { granted, denied }

/// The microphone, behind an interface so the recording flow runs in tests without a phone. The real one is
/// [RecordVoiceRecorder].
abstract class VoiceRecorder {
  /// Asks for the microphone permission when it is not decided yet (the system dialog shows the purpose text).
  Future<MicPermission> permission();

  /// Starts writing AAC-LC in an MP4 (M4A) file at [path].
  Future<void> start(String path);

  /// Stops and returns the path of the finished file.
  Future<String?> stop();

  /// Stops and throws the file away.
  Future<void> cancel();

  /// How loud it is, from 0 (silence) to 1, sampled while recording.
  Stream<double> levels(Duration every);

  Future<void> dispose();
}

/// [VoiceRecorder] over the `record` plugin. Mono AAC-LC at 48 kbit/s and 44.1 kHz: clear speech, about 360 KB
/// a minute, so five minutes stay far under the 8 MiB the server allows. Device-only: needs a microphone.
class RecordVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _recorder;
  AudioRecorder get _r => _recorder ??= AudioRecorder();

  @override
  Future<MicPermission> permission() async =>
      await _r.hasPermission() ? MicPermission.granted : MicPermission.denied;

  @override
  Future<void> start(String path) => _r.start(
    const RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 48000,
      sampleRate: 44100,
      numChannels: 1,
      // Speech: the phone's own noise suppression and echo handling help, and are free.
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
