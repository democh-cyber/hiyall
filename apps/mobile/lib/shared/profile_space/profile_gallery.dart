import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../chat_tokens.dart';
import '../person_avatar.dart';
import '../press_scale.dart';

/// What a screen reader says for one photo of a gallery: "Photo 2 of 5".
String photoSemantics(int index, int count) => 'Photo ${index + 1} of $count';

/// The pixels of one gallery photo through the same loader as avatars (tests replace it). The cache key is the
/// media id, never the URL: signed URLs expire within the hour. The thumbnail has a key of its own so it can
/// never be served in the place of the full size.
ImageProvider? photoImage(GalleryPhoto photo, {bool thumb = false}) {
  final url = thumb
      ? (photo.thumbUrl.isNotEmpty ? photo.thumbUrl : photo.url)
      : (photo.url.isNotEmpty ? photo.url : photo.thumbUrl);
  if (url.isEmpty) return null;
  final key = thumb ? 'photo:${photo.mediaId}:thumb' : 'photo:${photo.mediaId}';
  return photoProvider(url, key);
}

/// A row of the member's photos under the header. Tapping one opens the full-screen viewer at that photo.
/// The first photo is the profile photo.
class ProfileGalleryStrip extends StatelessWidget {
  final List<GalleryPhoto> photos;
  const ProfileGalleryStrip({super.key, required this.photos});

  static const tile = 88.0;

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) return const SizedBox.shrink();
    final t = ChatTokens.of(context);
    final pixels = (tile * MediaQuery.devicePixelRatioOf(context)).ceil();
    return SizedBox(
      height: tile + 8,
      child: ListView.separated(
        key: const Key('profile-gallery'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 24,
          vertical: 4,
        ),
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final image = photoImage(photos[i], thumb: true);
          return PressScale(
            key: Key('gallery-photo-$i'),
            borderRadius: BorderRadius.circular(16),
            minHeight: 48,
            semanticLabel: photoSemantics(i, photos.length),
            semanticHint: 'Opens the photo full screen',
            onTap: () => openPhotoViewer(context, photos, i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: tile,
                height: tile,
                child: ColoredBox(
                  color: t.elevated,
                  child: image == null
                      ? Icon(Icons.image_outlined, color: t.textTertiary)
                      : Image(
                          image: ResizeImage.resizeIfNeeded(
                            pixels,
                            pixels,
                            image,
                          ),
                          fit: BoxFit.cover,
                          excludeFromSemantics: true,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              Icon(Icons.image_outlined, color: t.textTertiary),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Opens the full-screen viewer above everything, including the dock. The route has no name, so nothing about
/// the photo ends up in a route log.
Future<void> openPhotoViewer(
  BuildContext context,
  List<GalleryPhoto> photos,
  int index,
) {
  final reduced = MediaQuery.disableAnimationsOf(context);
  final duration = reduced ? Duration.zero : const Duration(milliseconds: 200);
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (_, _, _) => PhotoViewer(
        photos: photos,
        initialIndex: index.clamp(0, photos.isEmpty ? 0 : photos.length - 1),
      ),
      transitionsBuilder: (_, animation, _, child) =>
          reduced ? child : FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// Photos on black: swipe between them (the swipe follows the text direction), pinch or double-tap to zoom,
/// close with the button or the back gesture. A screen reader hears "Photo 2 of 5" and gets actions for the
/// next and previous photo and for zooming.
class PhotoViewer extends StatefulWidget {
  final List<GalleryPhoto> photos;
  final int initialIndex;
  const PhotoViewer({super.key, required this.photos, this.initialIndex = 0});
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final PageController pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int index = widget.initialIndex;
  bool zoomed = false;

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  void go(int to) {
    if (to < 0 || to >= widget.photos.length) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      pages.jumpToPage(to);
    } else {
      pages.animateToPage(
        to,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              go(index + (rtl ? -1 : 1)),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              go(index + (rtl ? 1 : -1)),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  key: const Key('photo-viewer-pages'),
                  controller: pages,
                  physics: zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: photos.length,
                  onPageChanged: (i) => setState(() {
                    index = i;
                    zoomed = false;
                  }),
                  itemBuilder: (context, i) => _ZoomPage(
                    key: ValueKey(photos[i].mediaId),
                    photo: photos[i],
                    label: photoSemantics(i, photos.length),
                    onZoomed: (z) {
                      if (i == index && z != zoomed) {
                        setState(() => zoomed = z);
                      }
                    },
                    onNext: i + 1 < photos.length ? () => go(i + 1) : null,
                    onPrevious: i > 0 ? () => go(i - 1) : null,
                  ),
                ),
                PositionedDirectional(
                  top: 0,
                  start: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: IconButton(
                          key: const Key('photo-viewer-close'),
                          tooltip: 'Close',
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          color: Colors.white,
                          onPressed: () => Navigator.maybePop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ),
                  ),
                ),
                if (photos.length > 1)
                  PositionedDirectional(
                    bottom: 0,
                    start: 0,
                    end: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: ExcludeSemantics(
                            child: Container(
                              key: const Key('photo-viewer-indicator'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: Text(
                                '${index + 1} / ${photos.length}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
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

/// One photo that can be pinched and double-tapped. It reports whether it is zoomed in, so the pager stops
/// taking drags (they pan the photo then).
class _ZoomPage extends StatefulWidget {
  final GalleryPhoto photo;
  final String label;
  final ValueChanged<bool> onZoomed;
  final VoidCallback? onNext, onPrevious;
  const _ZoomPage({
    super.key,
    required this.photo,
    required this.label,
    required this.onZoomed,
    required this.onNext,
    required this.onPrevious,
  });
  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage>
    with SingleTickerProviderStateMixin {
  static const zoomedScale = 2.5;
  final controller = TransformationController();
  late final AnimationController motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<Matrix4>? tween;
  Offset tap = Offset.zero;
  bool zoomed = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    motion.addListener(() {
      final t = tween;
      if (t != null) controller.value = t.value;
    });
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    motion.dispose();
    super.dispose();
  }

  void _changed() {
    final now = controller.value.getMaxScaleOnAxis() > 1.02;
    if (now != zoomed) {
      zoomed = now;
      widget.onZoomed(now);
    }
  }

  /// Zooms in around [at], or back out when already zoomed.
  void toggle(Offset at) {
    final end = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(
              -at.dx * (zoomedScale - 1),
              -at.dy * (zoomedScale - 1),
              0,
              1,
            )
            ..scaleByDouble(zoomedScale, zoomedScale, zoomedScale, 1));
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = end;
      return;
    }
    tween = Matrix4Tween(
      begin: controller.value,
      end: end,
    ).animate(CurvedAnimation(parent: motion, curve: Curves.easeOutCubic));
    motion.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    image: true,
    customSemanticsActions: {
      if (widget.onNext != null)
        const CustomSemanticsAction(label: 'Next photo'): widget.onNext!,
      if (widget.onPrevious != null)
        const CustomSemanticsAction(label: 'Previous photo'):
            widget.onPrevious!,
      CustomSemanticsAction(label: zoomed ? 'Zoom out' : 'Zoom in'): () =>
          toggle(
            Offset(
              MediaQuery.sizeOf(context).width / 2,
              MediaQuery.sizeOf(context).height / 2,
            ),
          ),
    },
    child: ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (d) => tap = d.localPosition,
        onDoubleTap: () => toggle(tap),
        child: InteractiveViewer(
          transformationController: controller,
          minScale: 1,
          maxScale: 5,
          child: SizedBox.expand(child: _PhotoPixels(photo: widget.photo)),
        ),
      ),
    ),
  );
}

/// The thumbnail (already cached from the strip) under the full size, which fades in over it.
class _PhotoPixels extends StatelessWidget {
  final GalleryPhoto photo;
  const _PhotoPixels({required this.photo});

  @override
  Widget build(BuildContext context) {
    final thumb = photoImage(photo, thumb: true);
    final full = photoImage(photo);
    final reduced = MediaQuery.disableAnimationsOf(context);
    const broken = Center(
      child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb == null)
          broken
        else
          Image(
            image: thumb,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => broken,
          ),
        if (full != null)
          Image(
            image: full,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            gaplessPlayback: true,
            frameBuilder: (_, child, frame, sync) => sync
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: reduced
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: child,
                  ),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
      ],
    );
  }
}
