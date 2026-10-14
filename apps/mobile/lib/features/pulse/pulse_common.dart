import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../shared/person_avatar.dart';

/// "now", "5m", "3h", "2d", then a date: compact enough for a card header.
String shortAgo(DateTime at, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  final l = at.toLocal();
  return '${l.day}/${l.month}/${l.year % 100}';
}

const audienceLabels = {
  'public': 'Everyone',
  'followers': 'Followers',
  'friends': 'Friends',
};

IconData audienceIcon(String audience) => switch (audience) {
  'public' => Icons.public_rounded,
  'friends' => Icons.favorite_border_rounded,
  _ => Icons.group_outlined,
};

/// The audience a new post or story starts with, from the person's privacy.
String defaultAudience(String? setting) => switch (setting) {
  'public' => 'public',
  'followers' => 'followers',
  _ => 'friends',
};

/// A post, comment or story author's avatar.
class PulseAvatar extends StatelessWidget {
  final String name, userId;
  final String? avatarUrl;
  final double radius;
  const PulseAvatar(
    this.name, {
    super.key,
    this.radius = 20,
    this.userId = '',
    this.avatarUrl,
  });
  PulseAvatar.of(Person person, {Key? key, double radius = 20})
    : this(
        person.name,
        key: key,
        radius: radius,
        userId: person.userId,
        avatarUrl: person.avatarUrl,
      );
  @override
  Widget build(BuildContext context) => PersonAvatar(
    name: name,
    avatarUrl: avatarUrl,
    userId: userId,
    radius: radius,
  );
}

/// Builds the pixels for a post photo. Replaced in tests, which must not
/// reach the network or the on-disk image cache.
@visibleForTesting
ImageProvider Function(String url, String cacheKey) postPhotoFactory = (
  url,
  cacheKey,
) => CachedNetworkImageProvider(url, cacheKey: cacheKey);

/// Pixels worth decoding for a photo shown [logical] pixels wide on a screen
/// of density [dpr]: rounded up to a multiple of 64 so a layout that shifts a
/// little reuses the same decoded image, and never more than [cap] (the
/// server's longest edge). A 2048 px upload shown 360 px wide on a 3x phone
/// decodes at 1088 px instead of 2048: a quarter of the memory.
int photoDecodeWidth(double logical, double dpr, {int cap = 2048}) {
  if (!logical.isFinite || logical <= 0) return cap;
  final pixels = (logical * dpr).ceil();
  return (((pixels + 63) ~/ 64) * 64).clamp(64, cap);
}

/// A photo loaded from a signed URL but cached by media id, so a fresh URL
/// for the same photo never downloads it again. Decoded at layout width x
/// device pixel ratio ([photoDecodeWidth]), not at full size.
class PostPhoto extends StatelessWidget {
  final PostMedia media;
  final BoxFit fit;
  const PostPhoto(this.media, {super.key, this.fit = BoxFit.cover});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = media.url;
    final blank = ColoredBox(color: scheme.surfaceContainerHighest);
    if (url.isEmpty) return blank;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) => Stack(
        fit: StackFit.expand,
        children: [
          blank,
          Image(
            image: ResizeImage.resizeIfNeeded(
              photoDecodeWidth(box.maxWidth, dpr),
              null,
              postPhotoFactory(url, 'media:${media.mediaId}:full'),
            ),
            fit: fit,
            excludeFromSemantics: true,
            frameBuilder: (_, child, frame, synchronous) => synchronous
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: child,
                  ),
            errorBuilder: (_, _, _) => Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
