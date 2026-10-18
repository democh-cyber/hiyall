import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/avatar_upload.dart';
import '../core/chat/chat_api.dart';
import '../core/chat/chat_attachment.dart';
import '../core/chat/chat_blob_codec.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_jpeg.dart';
import '../core/chat/chat_media.dart';
import '../core/picked_file.dart';
import '../core/theme.dart';
import '../shared/press_scale.dart';
import 'chat_photo_states.dart';

/// Decoded chat images, most recently used last, held in memory only. It is
/// ours rather than Flutter's image cache: chat photos never go through the
/// shared cache, and nothing here is written to disk. Everything handed out is
/// a clone the caller must dispose.
class ChatImages {
  final int maxBytes;
  ChatImages({this.maxBytes = 48 << 20});
  final _lru = <String, ui.Image>{};
  final _pending = <String, Future<ui.Image>>{};
  int _bytes = 0;

  ui.Image? peek(String key) {
    final image = _lru.remove(key);
    if (image == null) return null;
    _lru[key] = image;
    return image.clone();
  }

  Future<ui.Image> obtain(String key, Future<ui.Image> Function() make) async {
    final hit = peek(key);
    if (hit != null) return hit;
    final image = await (_pending[key] ??= _store(key, make));
    return image.clone();
  }

  Future<ui.Image> _store(String key, Future<ui.Image> Function() make) async {
    try {
      final image = await make();
      _lru[key] = image;
      _bytes += image.width * image.height * 4;
      while (_bytes > maxBytes && _lru.length > 1) {
        final oldest = _lru.keys.first;
        final gone = _lru.remove(oldest)!;
        _bytes -= gone.width * gone.height * 4;
        gone.dispose();
      }
      return image;
    } finally {
      _pending.remove(key);
    }
  }

  int get count => _lru.length;

  void clear() {
    for (final image in _lru.values) {
      image.dispose();
    }
    _lru.clear();
    _bytes = 0;
  }

  /// Decodes a JPEG after checking it: the magic bytes, and that the size it
  /// declares is the size the descriptor promised. Throws [FormatException].
  Future<ui.Image> decodeJpeg(
    Uint8List bytes, {
    required int w,
    required int h,
    required int targetWidth,
  }) async {
    final dims = jpegDimensions(bytes);
    if (dims == null || dims.w != w || dims.h != h) {
      throw const FormatException('image does not match its descriptor');
    }
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: min(w, targetWidth),
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  Future<ui.Image> decodePixels(PreviewPixels p) {
    if (p.w < 1 ||
        p.h < 1 ||
        p.w > 32 ||
        p.h > 32 ||
        p.rgba.length != p.w * p.h * 4) {
      throw const FormatException('bad preview');
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      p.rgba,
      p.w,
      p.h,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }
}

final chatImagesProvider = Provider<ChatImages>((ref) {
  final images = ChatImages();
  ref.onDispose(images.clear);
  return images;
});

/// Why a photo could not be picked, in words to show.
String photoPickError(Object error) => switch (error) {
  PlatformException(:final code) when code.contains('access_denied') =>
    'Hiyall can’t reach your photos. Allow access in your device settings.',
  ChatFailure(:final message) => message,
  _ => 'Couldn’t open that photo. Try another one.',
};

enum PhotoSource { gallery, camera }

/// Opens the gallery or the camera and returns the chosen photo's bytes, or
/// null when the person backed out. The picker is asked for at most 4096 px:
/// the preparation step refuses anything over 40 megapixels.
Future<Uint8List?> pickChatPhoto(ImagePicker picker, PhotoSource source) async {
  final file = await picker.pickImage(
    source: source == PhotoSource.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxWidth: 4096,
    maxHeight: 4096,
    imageQuality: 90,
  );
  if (file == null) return null;
  // The picker's temporary copy is plaintext: it is deleted as soon as the bytes are read.
  final bytes = await readAndDeletePick(file);
  if (bytes.length > maxPhotoInput) {
    throw const ChatFailure(
      'PHOTO_TOO_LARGE',
      'That photo is too large to send.',
    );
  }
  return bytes;
}

/// What the attach menu can pick: a photo or a video, from the gallery or the camera.
enum AttachChoice { photoGallery, photoCamera, videoGallery, videoCamera }

/// The attach menu: photos and videos from the gallery, and the camera where the phone has one.
Future<AttachChoice?> showAttachSheet(BuildContext context) =>
    showModalBottomSheet<AttachChoice>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  'Send a photo or video',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              _AttachTile(
                key: const Key('attach-gallery'),
                icon: Icons.photo_library_rounded,
                tint: VibeColors.lilac,
                title: 'Choose photo',
                subtitle: 'Pick one from your gallery',
                onTap: () => Navigator.pop(context, AttachChoice.photoGallery),
              ),
              if (canTakePhoto) ...[
                const SizedBox(height: 8),
                _AttachTile(
                  key: const Key('attach-camera'),
                  icon: Icons.photo_camera_rounded,
                  tint: VibeColors.lime,
                  title: 'Take photo',
                  subtitle: 'Use your camera right now',
                  onTap: () => Navigator.pop(context, AttachChoice.photoCamera),
                ),
              ],
              const SizedBox(height: 8),
              _AttachTile(
                key: const Key('attach-video-gallery'),
                icon: Icons.video_library_rounded,
                tint: VibeColors.lilac,
                title: 'Choose video',
                subtitle: 'Up to 1 minute',
                onTap: () => Navigator.pop(context, AttachChoice.videoGallery),
              ),
              if (canTakePhoto) ...[
                const SizedBox(height: 8),
                _AttachTile(
                  key: const Key('attach-video-camera'),
                  icon: Icons.videocam_rounded,
                  tint: VibeColors.lime,
                  title: 'Record video',
                  subtitle: 'Up to 1 minute',
                  onTap: () => Navigator.pop(context, AttachChoice.videoCamera),
                ),
              ],
            ],
          ),
        ),
      ),
    );

class _AttachTile extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title, subtitle;
  final VoidCallback onTap;
  const _AttachTile({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressScale(
      onTap: onTap,
      semanticLabel: title,
      borderRadius: BorderRadius.circular(22),
      minHeight: 64,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tint,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: VibeColors.ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// The chosen photo with an optional caption, before anything is sent.
/// Returns the caption (possibly empty) to send, or null to cancel.
Future<String?> showPhotoPreview(
  BuildContext context,
  Uint8List bytes,
  String peerName,
) => showModalBottomSheet<String>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => _PhotoPreviewSheet(bytes: bytes, peerName: peerName),
);

class _PhotoPreviewSheet extends StatefulWidget {
  final Uint8List bytes;
  final String peerName;
  const _PhotoPreviewSheet({required this.bytes, required this.peerName});
  @override
  State<_PhotoPreviewSheet> createState() => _PhotoPreviewSheetState();
}

class _PhotoPreviewSheetState extends State<_PhotoPreviewSheet> {
  final caption = TextEditingController();
  @override
  void dispose() {
    caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(
            'Send to ${widget.peerName}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.lock_rounded,
                  size: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Photos are encrypted on this phone. Location and camera details are removed.',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: Semantics(
                    label: 'Photo to send',
                    image: true,
                    child: Image.memory(
                      widget.bytes,
                      key: const Key('photo-preview'),
                      fit: BoxFit.contain,
                      cacheWidth: 900,
                      errorBuilder: (_, _, _) => const SizedBox(
                        height: 120,
                        child: Center(child: Text('Preview unavailable')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('photo-caption'),
            controller: caption,
            maxLength: maxCaption,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            cursorColor: dark ? VibeColors.lime : VibeColors.ink,
            decoration: InputDecoration(
              labelText: 'Add a caption (optional)',
              counterText: '',
              floatingLabelBehavior: FloatingLabelBehavior.never,
              hintText: 'Add a caption (optional)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(26),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 14,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('photo-cancel'),
                  style: OutlinedButton.styleFrom(
                    overlayColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    shape: const StadiumBorder(),
                    side: BorderSide(color: scheme.outlineVariant),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  key: const Key('photo-send'),
                  style: FilledButton.styleFrom(
                    backgroundColor: VibeColors.lime,
                    foregroundColor: VibeColors.ink,
                    overlayColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: () => Navigator.pop(context, caption.text.trim()),
                  icon: const Icon(Icons.arrow_upward_rounded),
                  label: const Text('Send'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A message that was a photo this app cannot open: a bad descriptor, or a
/// newer format.
class UnsupportedPhoto extends StatelessWidget {
  final bool mine;
  const UnsupportedPhoto({super.key, required this.mine});
  @override
  Widget build(BuildContext context) {
    final color = mine
        ? VibeColors.ink
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      label: 'Unsupported photo',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported_outlined, size: 20, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Unsupported photo',
              key: const Key('photo-unsupported'),
              style: TextStyle(color: color, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// How wide a photo (and so its bubble content) is drawn: 62% of the screen,
/// at most 300.
double chatPhotoWidth(BuildContext context) =>
    min(MediaQuery.sizeOf(context).width * .62, 300.0);

/// The photo inside a message bubble: a blurred placeholder at the right
/// shape, the thumbnail once it has downloaded and decrypted, and the state of
/// the upload or download on top.
class PhotoBody extends ConsumerStatefulWidget {
  final ChatMessage message;
  final ChatEngine engine;
  final String conversationId, peerName;
  const PhotoBody({
    super.key,
    required this.message,
    required this.engine,
    required this.conversationId,
    required this.peerName,
  });
  @override
  ConsumerState<PhotoBody> createState() => _PhotoBodyState();
}

class _PhotoBodyState extends ConsumerState<PhotoBody> {
  ui.Image? blur, thumb;
  MediaProblem? problem;
  bool loading = false;
  double download = 0;
  int _epoch = 0;

  ChatAttachment get att => widget.message.attachment!;
  ChatImages get images => ref.read(chatImagesProvider);
  String get _thumbKey =>
      'thumb:${att.thumb.blobId ?? widget.message.messageId}';

  @override
  void initState() {
    super.initState();
    _loadPreview();
    _loadThumb();
  }

  @override
  void didUpdateWidget(PhotoBody old) {
    super.didUpdateWidget(old);
    // A retry after a failure, or the upload finishing, may make the
    // thumbnail reachable.
    if (old.message.status != widget.message.status &&
        thumb == null &&
        problem != MediaProblem.unavailable) {
      _loadThumb();
    }
  }

  @override
  void dispose() {
    _epoch++;
    blur?.dispose();
    thumb?.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    final images = this.images;
    final key = 'preview:${att.salt}';
    try {
      final image = await images.obtain(
        key,
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

  Future<void> _loadThumb() async {
    final epoch = ++_epoch;
    final images = this.images;
    final cached = images.peek(_thumbKey);
    if (cached != null) {
      setState(() {
        thumb?.dispose();
        thumb = cached;
        problem = null;
      });
      return;
    }
    final local = widget.engine.localThumb(widget.message.messageId);
    final media = widget.engine.media;
    if (local == null && (!att.uploaded || media == null)) return;
    setState(() {
      loading = true;
      problem = null;
      download = 0;
    });
    try {
      final image = await images.obtain(_thumbKey, () async {
        final bytes =
            local ??
            await media!.plaintext(
              widget.conversationId,
              att,
              BlobRole.thumb,
              onProgress: (v) {
                if (mounted && epoch == _epoch) setState(() => download = v);
              },
            );
        return images.decodeJpeg(
          bytes,
          w: att.thumb.w,
          h: att.thumb.h,
          targetWidth: 640,
        );
      });
      if (!mounted || epoch != _epoch) return image.dispose();
      setState(() {
        thumb?.dispose();
        thumb = image;
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
        builder: (_) => PhotoViewer(
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
    final who = m.mine ? 'Photo you sent' : 'Photo from ${widget.peerName}';
    final caption = att.caption.isEmpty ? '' : '. ${att.caption}';
    // What the picture is doing, when it is not simply there.
    final state = switch (problem) {
      MediaProblem.unavailable => ', expired',
      MediaProblem.corrupt => ', can’t be opened',
      MediaProblem.network || MediaProblem.other => ', couldn’t load',
      null => loading ? ', loading' : '',
    };
    return switch (m.status) {
      SendStatus.sending => 'Photo uploading$caption',
      SendStatus.failed => 'Photo not sent$caption',
      SendStatus.sent => '$who$state$caption',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = widget.message;
    final width = chatPhotoWidth(context);
    final aspect = att.aspect.clamp(.6, 1.8);
    final height = width / aspect;
    final progress = widget.engine.photoProgress(m.messageId);

    Widget layer(ui.Image image, {double blurSigma = 0}) {
      final raw = RawImage(
        image: image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        width: width,
        height: height,
      );
      return blurSigma == 0
          ? raw
          : ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
                tileMode: TileMode.clamp,
              ),
              child: raw,
            );
    }

    Widget overlay({required Widget child, String? key}) => Positioned.fill(
      child: ColoredBox(
        key: key == null ? null : Key(key),
        color: Colors.black45,
        child: Center(child: child),
      ),
    );

    final sending = m.status == SendStatus.sending;
    final failed = m.status == SendStatus.failed;
    final unavailable = problem == MediaProblem.unavailable;
    final retryable =
        problem == MediaProblem.network || problem == MediaProblem.other;
    final damaged = problem == MediaProblem.corrupt;
    return Semantics(
      label: label,
      image: true,
      button: m.status == SendStatus.sent && !unavailable && !damaged,
      child: GestureDetector(
        key: Key('photo-${m.messageId}'),
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
                if (blur != null) layer(blur!, blurSigma: 3),
                if (thumb != null) layer(thumb!),
                if (sending)
                  overlay(
                    key: 'photo-sending-${m.messageId}',
                    child: StreamBuilder<double>(
                      initialData: progress?.value ?? 0,
                      stream: progress?.changes,
                      builder: (context, snap) => UploadBadge(
                        key: Key('photo-stop-${m.messageId}'),
                        value: (snap.data ?? 0) > 0 ? snap.data : null,
                        onCancel: () => widget.engine.cancelPhoto(m.messageId),
                      ),
                    ),
                  )
                else if (failed)
                  overlay(
                    key: 'photo-failed-${m.messageId}',
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
                    key: 'photo-loading-${m.messageId}',
                    child: PhotoLoadingState(progress: download),
                  )
                else if (unavailable)
                  overlay(
                    key: 'photo-unavailable-${m.messageId}',
                    child: const PhotoExpiredState(),
                  )
                else if (damaged)
                  overlay(
                    key: 'photo-damaged-${m.messageId}',
                    child: const PhotoDamagedState(),
                  )
                else if (retryable)
                  overlay(
                    key: 'photo-download-failed-${m.messageId}',
                    child: PhotoRetryState(
                      retryKey: Key('photo-retry-${m.messageId}'),
                      onRetry: _loadThumb,
                    ),
                  ),
                // A soft inner edge so the photo sits in its bubble.
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

/// A dark round plate for an icon or progress ring on top of a photo. The
/// child is centred on the plate exactly.
class BadgeCircle extends StatelessWidget {
  final Widget child;
  const BadgeCircle({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    width: 56,
    height: 56,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: Color(0x73000000),
    ),
    child: child,
  );
}

/// The ring and cancel cross on an uploading photo: one plate, the ring and
/// the cross centred on the same point, and the whole plate is the target.
class UploadBadge extends StatelessWidget {
  final double? value;
  final VoidCallback onCancel;
  const UploadBadge({super.key, required this.value, required this.onCancel});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Cancel upload',
    child: PressScale(
      onTap: onCancel,
      semanticLabel: 'Cancel upload',
      borderRadius: BorderRadius.circular(28),
      child: BadgeCircle(
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                value: value,
                color: Colors.white,
                backgroundColor: Colors.white24,
                strokeWidth: 3,
              ),
            ),
            const Icon(Icons.close_rounded, color: Colors.white, size: 22),
          ],
        ),
      ),
    ),
  );
}

/// Full-screen view of one photo: pinch to zoom, loads the full image from the
/// cache or the network, and shows the thumbnail meanwhile. There is no save or
/// share in this first version.
class PhotoViewer extends ConsumerStatefulWidget {
  final ChatMessage message;
  final ChatEngine engine;
  final String conversationId, peerName;
  const PhotoViewer({
    super.key,
    required this.message,
    required this.engine,
    required this.conversationId,
    required this.peerName,
  });
  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer> {
  ui.Image? thumb, full;
  MediaProblem? problem;
  double progress = 0;
  bool loading = true;
  bool _gone = false;

  ChatAttachment get att => widget.message.attachment!;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _gone = true;
    thumb?.dispose();
    full?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final images = ref.read(chatImagesProvider);
    final media = widget.engine.media;
    setState(() {
      loading = true;
      problem = null;
      progress = 0;
    });
    final cachedThumb = images.peek('thumb:${att.thumb.blobId}');
    if (cachedThumb != null) setState(() => thumb = cachedThumb);
    if (media == null) {
      setState(() {
        loading = false;
        problem = MediaProblem.other;
      });
      return;
    }
    try {
      final image = await images.obtain('full:${att.full.blobId}', () async {
        final bytes = await media.plaintext(
          widget.conversationId,
          att,
          BlobRole.full,
          onProgress: (v) {
            if (!_gone) setState(() => progress = v);
          },
        );
        return images.decodeJpeg(
          bytes,
          w: att.full.w,
          h: att.full.h,
          targetWidth: 2560,
        );
      });
      if (_gone) return image.dispose();
      setState(() {
        full = image;
        loading = false;
      });
    } catch (e) {
      if (_gone) return;
      setState(() {
        loading = false;
        problem = e is ChatMediaFailure ? e.problem : MediaProblem.corrupt;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = full ?? thumb;
    final caption = att.caption;
    String? note;
    if (problem == MediaProblem.unavailable) {
      note = 'This photo has expired. Photos are removed 30 days after they’re sent.';
    } else if (problem == MediaProblem.corrupt) {
      note = 'This photo is damaged and can’t be opened.';
    } else if (problem != null) {
      note = 'The photo didn’t load. Check your connection.';
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (shown != null)
            Semantics(
              label: caption.isEmpty
                  ? 'Photo from ${widget.message.mine ? 'you' : widget.peerName}'
                  : caption,
              image: true,
              child: InteractiveViewer(
                key: const Key('photo-zoom'),
                minScale: 1,
                maxScale: 5,
                child: Center(
                  child: RawImage(
                    image: shown,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          if (loading)
            Positioned(
              bottom: 96,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  key: const Key('photo-viewer-loading'),
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    value: progress > 0 ? progress : null,
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
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
                      key: const Key('photo-viewer-note'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    if (problem == MediaProblem.network ||
                        problem == MediaProblem.other)
                      TextButton(
                        key: const Key('photo-viewer-retry'),
                        onPressed: _load,
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ),
            ),
          if (caption.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  color: Colors.black54,
                  child: Text(
                    caption,
                    key: const Key('photo-viewer-caption'),
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                key: const Key('photo-viewer-close'),
                tooltip: 'Close photo',
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

/// The failed state of an outgoing photo under its bubble, with Retry and Delete.
class FailedPhotoActions extends StatelessWidget {
  final ChatMessage message;
  final String error;
  final VoidCallback onRetry, onDelete;

  /// "photo" for photos; "text" when the same card sits under a message that
  /// was not sent (the keys differ so tests can tell them apart).
  final String keyPrefix;
  const FailedPhotoActions({
    super.key,
    required this.message,
    required this.error,
    required this.onRetry,
    required this.onDelete,
    this.keyPrefix = 'photo',
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget action(
      Key key,
      String label,
      VoidCallback onTap, {
      bool main = false,
    }) => PressScale(
      key: key,
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(100),
      minHeight: 48,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
        decoration: BoxDecoration(
          color: main ? VibeColors.lime : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
          border: main
              ? null
              : Border.all(
                  color: dark
                      ? const Color(0xff5a6153)
                      : const Color(0xffc9cfbb),
                ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13.5,
            color: main ? VibeColors.ink : scheme.onSurface,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
            decoration: BoxDecoration(
              color: dark ? const Color(0xff31362f) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: scheme.error.withValues(alpha: dark ? .6 : .5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 16,
                        color: scheme.error,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        error,
                        key: Key('$keyPrefix-error-${message.messageId}'),
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: scheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    action(
                      Key('$keyPrefix-delete-${message.messageId}'),
                      'Delete',
                      onDelete,
                    ),
                    const SizedBox(width: 8),
                    action(
                      Key('$keyPrefix-send-retry-${message.messageId}'),
                      'Retry',
                      onRetry,
                      main: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
