import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

/// The video player of the full-screen viewer, as an interface so the viewer's states and controls are tested
/// without a phone. The real one is [DeviceVideoPlayer].
abstract class ChatVideoPlayer extends ChangeNotifier {
  /// Opens [file] (the decrypted video, in the private play folder). Throws when it cannot be played.
  Future<void> open(File file);
  bool get ready;
  bool get playing;
  bool get ended;
  Duration get position;
  Duration get duration;

  /// The picture, to place inside the viewer.
  Widget buildSurface();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration to);
}

/// [ChatVideoPlayer] over `video_player` (ExoPlayer on Android, AVPlayer on iOS). It plays a local file only:
/// the video was fetched, hash-checked and decrypted before it got here. Device-only.
class DeviceVideoPlayer extends ChatVideoPlayer {
  VideoPlayerController? _c;

  void _changed() => notifyListeners();

  @override
  Future<void> open(File file) async {
    final controller = VideoPlayerController.file(
      file,
      // Playing a message must not take the music of another app away for good, and must not mix in.
      videoPlayerOptions: VideoPlayerOptions(),
    );
    _c = controller;
    await controller.initialize();
    controller.addListener(_changed);
    notifyListeners();
  }

  @override
  bool get ready => _c?.value.isInitialized ?? false;
  @override
  bool get playing => _c?.value.isPlaying ?? false;
  @override
  bool get ended {
    final v = _c?.value;
    return v != null &&
        v.isInitialized &&
        v.position >= v.duration &&
        !v.isPlaying;
  }

  @override
  Duration get position => _c?.value.position ?? Duration.zero;
  @override
  Duration get duration => _c?.value.duration ?? Duration.zero;

  @override
  Widget buildSurface() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    return AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c));
  }

  @override
  Future<void> play() async {
    final c = _c;
    if (c == null) return;
    if (ended) await c.seekTo(Duration.zero);
    await c.play();
  }

  @override
  Future<void> pause() async => _c?.pause();

  @override
  Future<void> seekTo(Duration to) async => _c?.seekTo(to);

  @override
  void dispose() {
    final c = _c;
    _c = null;
    c?.removeListener(_changed);
    c?.dispose();
    super.dispose();
  }
}
