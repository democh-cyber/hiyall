import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:pro_video_editor/pro_video_editor.dart';

import '../picked_file.dart' show deletePickedFile;
import 'chat_api.dart';
import 'chat_av.dart';
import 'chat_av_outbox.dart' show PreparedVideo;
import 'chat_blob_codec.dart';
import 'chat_mp4.dart';
import 'chat_play_files.dart';

/// Turns a picked or filmed video into what the chat sends. It sits behind an interface so the sending flow
/// runs in tests without a phone; the real one is [ProVideoPreparer].
abstract class VideoPreparer {
  /// [sourcePath] is the picker's file. It is deleted when preparation finishes, however it ends (it is a
  /// plaintext copy of the video).
  Future<PreparedVideo> prepare(
    String sourcePath, {
    void Function(double progress)? onProgress,
  });
}

/// The picture size a video is scaled to: inside 1280 x 720 (or 720 x 1280 for a portrait video), keeping its
/// proportions, never enlarged, both sides even (H.264 needs that).
Size videoTargetSize(Size source) {
  final w = source.width, h = source.height;
  if (w <= 0 || h <= 0) return const Size(0, 0);
  final maxLong = maxVideoLongSide.toDouble();
  final maxShort = maxVideoShortSide.toDouble();
  final scale = min(1.0, min(maxLong / max(w, h), maxShort / min(w, h)));
  int even(double v) => max(2, (v * scale / 2).round() * 2);
  final tw = even(w), th = even(h);
  return Size(tw.toDouble(), th.toDouble());
}

/// The video bitrate (bits per second) that keeps [seconds] of video and 128 kbit/s of sound under about 28
/// MiB: at most 2.5 Mbit/s, which is plenty at 720p on a phone screen.
int videoBitrateFor(double seconds, {int cap = 2500000}) {
  final budget = 28 * 1024 * 1024 * 8 / max(seconds, 1) - 128000;
  return min(cap, max(300000, budget.floor()));
}

/// [VideoPreparer] over `pro_video_editor` (native: Android's Media3 Transformer and Apple's AVFoundation, no
/// FFmpeg). It re-encodes to at most 720p, caps the bitrate so a minute stays under 32 MiB, takes a poster
/// frame, and then removes the metadata itself with [scrubMp4]: the plugin's own guarantee about GPS tags is
/// not relied on. The poster goes through the same Rust image pipeline as a photo (decode limits, a JPEG
/// without EXIF, the tiny blurred preview). Device-only: needs the native encoder.
class ProVideoPreparer implements VideoPreparer {
  ProVideoPreparer({required this.codec, required this.files});
  final ChatBlobCodec codec;
  final PlayFiles files;

  @override
  Future<PreparedVideo> prepare(
    String sourcePath, {
    void Function(double progress)? onProgress,
  }) async {
    final source = File(sourcePath);
    File? rendered;
    try {
      final editor = ProVideoEditor.instance;
      final video = EditorVideo.file(source);
      final VideoMetadata meta;
      try {
        meta = await editor.getMetadata(video);
      } catch (_) {
        throw const ChatFailure(
          'VIDEO_UNREADABLE',
          'That video couldn’t be opened. Try another one.',
        );
      }
      final seconds = meta.duration.inMilliseconds / 1000;
      if (meta.duration.inMilliseconds < minMediaMs) {
        throw const ChatFailure(
          'VIDEO_UNREADABLE',
          'That video couldn’t be opened. Try another one.',
        );
      }
      // Half a second of slack for containers that round up.
      if (meta.duration.inMilliseconds > maxVideoMs + 500) {
        throw const ChatFailure(
          'VIDEO_LENGTH',
          'Videos can be up to 1 minute long. Pick a shorter one.',
        );
      }
      final target = videoTargetSize(meta.resolution);
      if (target.width < 2) {
        throw const ChatFailure(
          'VIDEO_UNREADABLE',
          'That video couldn’t be opened. Try another one.',
        );
      }
      Uint8List? bytes;
      var bitrate = videoBitrateFor(seconds);
      for (var attempt = 0; attempt < 2 && bytes == null; attempt++) {
        rendered = await files.reserve('mp4');
        final data = VideoRenderData(
          videoSegments: [VideoSegment(video: video)],
          qualityConfig: VideoQualityConfig.custom(
            bitrate: bitrate,
            resolution: target,
          ),
          bitrate: bitrate,
          maxFrameRate: 30,
          enableAudio: true,
          shouldOptimizeForNetworkUse: true,
        );
        final progress = editor
            .progressStreamById(data.id)
            .listen(
              (p) => onProgress?.call(p.progress.clamp(0.0, 1.0).toDouble()),
              onError: (_) {},
            );
        try {
          await editor.renderVideoToFile(rendered.path, data);
        } catch (_) {
          throw const ChatFailure(
            'VIDEO_UNREADABLE',
            'That video couldn’t be prepared. Try another one.',
          );
        } finally {
          await progress.cancel();
        }
        final out = await rendered.readAsBytes();
        await files.delete(rendered);
        rendered = null;
        if (out.length <= maxVideoPlain) {
          bytes = out;
        } else if (attempt == 0) {
          bitrate = max(300000, bitrate ~/ 2);
        }
      }
      if (bytes == null) {
        throw const ChatFailure(
          'VIDEO_TOO_LARGE',
          'That video is too large to send. Try a shorter one.',
        );
      }
      final Uint8List clean;
      try {
        clean = scrubMp4(bytes);
        if (remainingMetadata(clean).isNotEmpty) {
          throw const FormatException('metadata left');
        }
      } on FormatException {
        throw const ChatFailure(
          'VIDEO_UNREADABLE',
          'That video couldn’t be prepared. Try another one.',
        );
      }
      // The poster: a frame half a second in (or the middle of a very short clip), through the photo pipeline.
      final at = Duration(
        milliseconds: min(500, meta.duration.inMilliseconds ~/ 2),
      );
      final frames = await editor.getThumbnails(
        ThumbnailConfigs(
          video: video,
          outputSize: Size(
            target.width >= target.height
                ? 640
                : 640 * target.width / target.height,
            target.width >= target.height
                ? 640 * target.height / target.width
                : 640,
          ),
          timestamps: [at],
          jpegQuality: 85,
        ),
      );
      if (frames.isEmpty) {
        throw const ChatFailure(
          'VIDEO_UNREADABLE',
          'That video couldn’t be prepared. Try another one.',
        );
      }
      final PreparedPhoto poster;
      try {
        poster = await codec.prepare(frames.first);
      } catch (_) {
        throw const ChatFailure(
          'VIDEO_UNREADABLE',
          'That video couldn’t be prepared. Try another one.',
        );
      }
      return PreparedVideo(
        bytes: clean,
        w: target.width.round(),
        h: target.height.round(),
        durationMs: meta.duration.inMilliseconds.clamp(minMediaMs, maxVideoMs),
        poster: poster.thumb,
        posterW: poster.thumbW,
        posterH: poster.thumbH,
        preview: poster.preview,
      );
    } finally {
      await files.delete(rendered);
      await deletePickedFile(sourcePath);
    }
  }
}
