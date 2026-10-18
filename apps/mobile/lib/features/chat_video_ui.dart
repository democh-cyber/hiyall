import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/chat/chat_api.dart';
import '../core/chat/chat_attachment.dart' show SendStatus;
import '../core/chat/chat_av.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_media.dart';
import '../core/chat/chat_play_files.dart';
import '../core/chat/chat_video_player.dart';
import '../shared/chat_tokens.dart';
import 'chat_av_providers.dart';
import 'chat_parts.dart';
import 'chat_photo.dart';
import 'chat_photo_states.dart';

// Videos in the conversation: picking or filming one, the bubble with its poster, and the full-screen player.
// Rules and limits: docs/security/14-encrypted-chat-attachments.md ("Voice messages and videos").

/// Makes the player of the full-screen viewer. The real one needs a phone.
final chatVideoPlayerFactoryProvider = Provider<ChatVideoPlayer Function()>(
  (_) => DeviceVideoPlayer.new,
);

/// Opens the gallery or the camera for a video of at most a minute and returns the picker's file path, or null
/// when the person backed out. The file is a plaintext copy: [VideoPreparer.prepare] deletes it.
Future<String?> pickChatVideo(ImagePicker picker, PhotoSource source) async {
  final file = await picker.pickVideo(
    source: source == PhotoSource.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxDuration: const Duration(milliseconds: maxVideoMs),
  );
  return file?.path;
}

/// Why a video could not be picked or prepared, in words to show.
String videoFailureText(Object error) => switch (error) {
  ChatFailure(
    code: 'VIDEO_LENGTH' || 'VIDEO_TOO_LARGE' || 'VIDEO_UNREADABLE',
    :final message,
  ) =>
    message,
  _ => 'Couldn’t open that video. Try another one.',
};

/// How wide a video bubble is: 62 % of the screen, at most 300 dp (as a photo).
double chatVideoWidth(BuildContext context) => chatPhotoWidth(context);

// ------------------------------------------------------------- the bubble

/// A video in a bubble: the blurred preview at the right shape, the poster once it has downloaded and
/// decrypted, a play badge and the length. Tapping opens the full-screen player.
class VideoBody extends ConsumerStatefulWidget {
  final ChatMessage message;
  final ChatEngine engine;
  final String conversationId, peerName;
  const VideoBody({
    super.key,
    required this.message,
    required this.engine,
    required this.conversationId,
    required this.peerName,
  });
  @override
  ConsumerState<VideoBody> createState() => _VideoBodyState();
}

class _VideoBodyState extends ConsumerState<VideoBody> {
  ui.Image? blur, poster;
  MediaProblem? problem;
  bool loading = false;
  double download = 0;
  int _epoch = 0;

  VideoAttachment get att => widget.message.video!;
  String get _posterKey =>
      'poster:${att.poster.blobId ?? widget.message.messageId}';

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
    unawaited(_loadPoster());
  }

  @override
  void didUpdateWidget(VideoBody old) {
    super.didUpdateWidget(old);
    if (old.message.status != widget.message.status &&
        poster == null &&
        problem != MediaProblem.unavailable) {
      unawaited(_loadPoster());
    }
  }

  @override
  void dispose() {
    _epoch++;
    blur?.dispose();
    poster?.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    final images = ref.read(chatImagesProvider);
    try {
      final image = await images.obtain(
        'preview:${att.salt}',
        () async => images.decodePixels(
          await widget.engine.blobCodec.previewPixels(att.preview),
        ),
      );
      if (!mounted) return image.dispose();
      setState(() {
        blur?.dispose();
        blur = image;
      });
    } catch (_) {
      // The placeholder is a nicety; the grey box stays.
    }
  }

  Future<void> _loadPoster() async {
    final epoch = ++_epoch;
    final images = ref.read(chatImagesProvider);
    final cached = images.peek(_posterKey);
    if (cached != null) {
      setState(() {
        poster?.dispose();
        poster = cached;
        problem = null;
      });
      return;
    }
    final local = widget.engine.localPoster(widget.message.messageId);
    final media = widget.engine.media;
    if (local == null && (!att.uploaded || media == null)) return;
    setState(() {
      loading = true;
      problem = null;
      download = 0;
    });
    try {
      final image = await images.obtain(_posterKey, () async {
        final bytes =
            local ??
            await media!.plaintextBlob(
              widget.conversationId,
              att.posterSpec,
              onProgress: (v) {
                if (mounted && epoch == _epoch) setState(() => download = v);
              },
            );
        return images.decodeJpeg(
          bytes,
          w: att.posterW,
          h: att.posterH,
          targetWidth: 640,
        );
      });
      if (!mounted || epoch != _epoch) return image.dispose();
      setState(() {
        poster?.dispose();
        poster = image;
        loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        loading = false;
        problem = e is ChatMediaFailure ? e.problem : MediaProblem.corrupt;
      });
    }
  }

  void open() {
    if (widget.message.status != SendStatus.sent || !att.uploaded) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => VideoViewer(
          message: widget.message,
          engine: widget.engine,
          conversationId: widget.conversationId,
          peerName: widget.peerName,
        ),
      ),
    );
  }

  String get label {
    final m = widget.message;
    final who = m.mine ? 'Video you sent' : 'Video from ${widget.peerName}';
    final length = clockOf(att.durationMs);
    return switch (m.status) {
      SendStatus.sending => 'Video uploading, $length',
      SendStatus.failed => 'Video not sent, $length',
      SendStatus.sent => switch (problem) {
        MediaProblem.unavailable => '$who, $length, expired',
        MediaProblem.corrupt => '$who, $length, can’t be opened',
        MediaProblem.network ||
        MediaProblem.other => '$who, $length, couldn’t load',
        null => '$who, $length',
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = widget.message;
    final width = chatVideoWidth(context);
    final aspect = att.aspect.clamp(.6, 1.8);
    final height = width / aspect;
    final sending = m.status == SendStatus.sending;
    final failed = m.status == SendStatus.failed;
    final unavailable = problem == MediaProblem.unavailable;
    final damaged = problem == MediaProblem.corrupt;
    final retryable =
        problem == MediaProblem.network || problem == MediaProblem.other;
    final progress = widget.engine.avProgress(m.messageId);

    Widget layer(ui.Image image, {double sigma = 0}) {
      final raw = RawImage(
        image: image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        width: width,
        height: height,
      );
      return sigma == 0
          ? raw
          : ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.clamp,
              ),
              child: raw,
            );
    }

    Widget overlay({required Widget child, required String key}) =>
        Positioned.fill(
          child: ColoredBox(
            key: Key(key),
            color: Colors.black45,
            child: Center(child: child),
          ),
        );

    final idle = !sending && !failed && !loading && problem == null;
    return Semantics(
      label: label,
      button: m.status == SendStatus.sent && !unavailable && !damaged,
      child: GestureDetector(
        key: Key('video-${m.messageId}'),
        onTap: unavailable || damaged ? null : open,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: scheme.surfaceContainerHighest),
                if (blur != null) layer(blur!, sigma: 3),
                if (poster != null) layer(poster!),
                if (sending)
                  overlay(
                    key: 'video-sending-${m.messageId}',
                    child: StreamBuilder<double>(
                      initialData: progress?.value ?? 0,
                      stream: progress?.changes,
                      builder: (context, snap) => UploadBadge(
                        key: Key('video-stop-${m.messageId}'),
                        value: (snap.data ?? 0) > 0 ? snap.data : null,
                        onCancel: () => widget.engine.cancelAv(m.messageId),
                      ),
                    ),
                  )
                else if (failed)
                  overlay(
                    key: 'video-failed-${m.messageId}',
                    child: const BadgeCircle(
                      child: Icon(
                        Icons.priority_high_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  )
                else if (loading)
                  overlay(
                    key: 'video-loading-${m.messageId}',
                    child: PhotoLoadingState(progress: download),
                  )
                else if (unavailable)
                  overlay(
                    key: 'video-unavailable-${m.messageId}',
                    child: const PhotoExpiredState(),
                  )
                else if (damaged)
                  overlay(
                    key: 'video-damaged-${m.messageId}',
                    child: const PhotoDamagedState(),
                  )
                else if (retryable)
                  overlay(
                    key: 'video-download-failed-${m.messageId}',
                    child: PhotoRetryState(
                      retryKey: Key('video-retry-${m.messageId}'),
                      onRetry: _loadPoster,
                    ),
                  ),
                if (idle ||
                    (m.status == SendStatus.sent &&
                        poster == null &&
                        !loading &&
                        problem == null))
                  const Center(
                    child: BadgeCircle(
                      key: Key('video-play-badge'),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: clampedChrome(
                    context,
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Text(
                        clockOf(att.durationMs),
                        key: Key('video-length-${m.messageId}'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .14),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- the viewer

/// Full-screen video: loads the video (from the cache or the network, with its progress), checks and decrypts
/// it, writes the decrypted file to the private play folder only for as long as the viewer is open, and plays
/// it with a play/pause button and a scrubber. The file is deleted when the viewer closes.
class VideoViewer extends ConsumerStatefulWidget {
  final ChatMessage message;
  final ChatEngine engine;
  final String conversationId, peerName;
  const VideoViewer({
    super.key,
    required this.message,
    required this.engine,
    required this.conversationId,
    required this.peerName,
  });
  @override
  ConsumerState<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends ConsumerState<VideoViewer> {
  ChatVideoPlayer? player;
  File? file;
  late final PlayFiles _files;
  MediaProblem? problem;
  double progress = 0;
  bool loading = true, _gone = false;

  VideoAttachment get att => widget.message.video!;

  @override
  void initState() {
    super.initState();
    _files = ref.read(playFilesProvider);
    unawaited(_load());
  }

  @override
  void dispose() {
    _gone = true;
    final p = player;
    final f = file;
    player = null;
    p?.dispose();
    if (f != null) unawaited(_files.delete(f));
    super.dispose();
  }

  Future<void> _load() async {
    final media = widget.engine.media;
    setState(() {
      loading = true;
      problem = null;
      progress = 0;
    });
    if (media == null) {
      setState(() {
        loading = false;
        problem = MediaProblem.other;
      });
      return;
    }
    final files = ref.read(playFilesProvider);
    final factory = ref.read(chatVideoPlayerFactoryProvider);
    try {
      final bytes = await media.plaintextBlob(
        widget.conversationId,
        att.videoSpec,
        onProgress: (v) {
          if (!_gone) setState(() => progress = v);
        },
      );
      if (_gone) return;
      final written = await files.write(bytes, 'mp4');
      if (_gone) {
        await files.delete(written);
        return;
      }
      file = written;
      final next = factory();
      await next.open(written);
      if (_gone) {
        next.dispose();
        return;
      }
      next.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() {
        player = next;
        loading = false;
      });
      unawaited(next.play());
    } catch (e) {
      if (_gone) return;
      setState(() {
        loading = false;
        problem = e is ChatMediaFailure ? e.problem : MediaProblem.corrupt;
      });
    }
  }

  String _clock(Duration d) => clockOf(d.inMilliseconds);

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final p = player;
    String? note;
    if (problem == MediaProblem.unavailable) {
      note = 'This video has expired. Videos are removed 30 days after they’re sent.';
    } else if (problem == MediaProblem.corrupt) {
      note = 'This video is damaged and can’t be played.';
    } else if (problem != null) {
      note = 'The video didn’t load. Check your connection.';
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (p != null)
            Semantics(
              label:
                  'Video from ${widget.message.mine ? 'you' : widget.peerName}',
              child: GestureDetector(
                key: const Key('video-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(p.playing ? p.pause() : p.play()),
                child: Center(child: p.buildSurface()),
              ),
            ),
          if (loading)
            Center(
              child: SizedBox(
                key: const Key('video-viewer-loading'),
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  value: progress > 0 ? progress : null,
                  color: Colors.white,
                  strokeWidth: 3,
                ),
              ),
            ),
          if (note != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      note,
                      key: const Key('video-viewer-note'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    if (problem == MediaProblem.network ||
                        problem == MediaProblem.other)
                      TextButton(
                        key: const Key('video-viewer-retry'),
                        onPressed: _load,
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ),
            ),
          if (p != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        key: const Key('video-play-pause'),
                        tooltip: p.playing
                            ? 'Pause'
                            : (p.ended ? 'Replay' : 'Play'),
                        onPressed: () =>
                            unawaited(p.playing ? p.pause() : p.play()),
                        icon: Icon(
                          p.playing
                              ? Icons.pause_rounded
                              : (p.ended
                                    ? Icons.replay_rounded
                                    : Icons.play_arrow_rounded),
                          color: Colors.white,
                          size: 30,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                      ),
                      Expanded(
                        child: Semantics(
                          label: 'Video position',
                          value:
                              '${_clock(p.position)} of ${_clock(p.duration)}',
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: t.lime,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: t.lime,
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 18,
                              ),
                            ),
                            child: Slider(
                              key: const Key('video-scrubber'),
                              value: min(
                                p.position.inMilliseconds.toDouble(),
                                max(1, p.duration.inMilliseconds).toDouble(),
                              ),
                              max: max(1, p.duration.inMilliseconds).toDouble(),
                              onChanged: (v) => unawaited(
                                p.seekTo(Duration(milliseconds: v.round())),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Text(
                        '${_clock(p.position)} / ${_clock(p.duration)}',
                        key: const Key('video-viewer-time'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: IconButton(
                key: const Key('video-viewer-close'),
                tooltip: 'Close video',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                style: IconButton.styleFrom(backgroundColor: Colors.black45),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The calm modal shown while a picked video is re-encoded (a few seconds): what is happening and, when the
/// encoder reports it, how far along.
class PreparingVideo extends StatelessWidget {
  final ValueListenable<double> progress;
  const PreparingVideo({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Dialog(
      backgroundColor: t.elevated,
      child: Padding(
        key: const Key('preparing-video'),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Preparing your video',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: t.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Making it smaller and removing its location and other tags before it is encrypted.',
              style: TextStyle(color: t.textSecondary, height: 1.35),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, v, _) =>
                  LinearProgressIndicator(value: v > 0 ? v : null),
            ),
          ],
        ),
      ),
    );
  }
}
