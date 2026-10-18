import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'avatar_gradient.dart';

/// The key an avatar is cached under. Photo URLs are signed and expire within
/// the hour, so the query string is dropped: a refreshed URL for the same
/// photo is the same entry and never downloads it again.
String avatarCacheKey(String userId, String url) {
  final path = Uri.tryParse(url)?.path;
  return 'avatar:$userId:${path == null || path.isEmpty ? url : path}';
}

/// Builds the pixels for a signed avatar URL. Replaced in tests, which must not
/// reach the network or the on-disk image cache.
typedef AvatarImageFactory = ImageProvider Function(
  String url,
  String cacheKey,
);

ImageProvider _cachedAvatar(String url, String cacheKey) =>
    CachedNetworkImageProvider(url, cacheKey: cacheKey);

/// Any signed photo URL as an [ImageProvider] under [cacheKey] (a gallery photo: `photo:<media id>`), through the
/// same loader as avatars, so tests replace both at once.
ImageProvider photoProvider(String url, String cacheKey) =>
    PersonAvatar.imageFactory(url, cacheKey);

/// A person's photo as an [ImageProvider] cached by [avatarCacheKey], for
/// places that take an image rather than a widget. Null without a URL.
ImageProvider? avatarProvider(String userId, String? url) =>
    url == null || url.isEmpty
    ? null
    : PersonAvatar.imageFactory(url, avatarCacheKey(userId, url));

/// A member's circular avatar: their photo when they have one, otherwise the
/// first letter of their name on a gradient derived from their id (see
/// [avatarGradient]), so it is the same on every screen. The photo only replaces the fill; rings,
/// country badges and online dots belong to the caller and sit around it.
class PersonAvatar extends StatelessWidget {
  final String name;

  /// Signed thumbnail (or full-size) URL; null shows the initial.
  final String? avatarUrl;

  /// A photo chosen on this device and not sent yet; shown instead of [avatarUrl].
  final Uint8List? bytes;

  /// Part of the cache key, so two people never share an image.
  final String userId;
  final double radius;

  /// Overrides the gradient with one flat colour, for avatars that carry a
  /// meaning of their own (a notification's kind). Leave null for people.
  final Color? tint;

  /// Replaces the initial-on-tint fill, for avatars with their own artwork.
  /// It also shows under the photo while that loads, and if it fails.
  final Widget? fallback;

  /// Merged over the default initial style, whose size follows [radius].
  final TextStyle? initialStyle;

  /// Draws a rounded square of this corner radius instead of a circle.
  final double? cornerRadius;

  @visibleForTesting
  static AvatarImageFactory imageFactory = _cachedAvatar;

  const PersonAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.bytes,
    this.userId = '',
    this.radius = 20,
    this.tint,
    this.fallback,
    this.initialStyle,
    this.cornerRadius,
  });

  /// The letter shown without a photo; an `@` in front of a username is skipped.
  static String initialOf(String name) =>
      name
          .trim()
          .replaceFirst('@', '')
          .trim()
          .characters
          .firstOrNull
          ?.toUpperCase() ??
      '?';

  Widget _initial() => DecoratedBox(
    decoration: tint != null
        ? BoxDecoration(color: tint)
        : BoxDecoration(
            gradient: avatarGradient(userId.isNotEmpty ? userId : name.trim()),
          ),
    child: Center(
      child: Text(
        initialOf(name),
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: VibeColors.ink,
          fontWeight: FontWeight.w800,
          fontSize: radius * .8,
        ).merge(initialStyle),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final base = fallback ?? _initial();
    final url = avatarUrl;
    Widget fill = base;
    final local = bytes;
    if (local != null || (url != null && url.isNotEmpty)) {
      final scale = MediaQuery.devicePixelRatioOf(context);
      final pixels = (size * scale).ceil();
      fill = Stack(
        fit: StackFit.expand,
        children: [
          base,
          Image(
            image: ResizeImage.resizeIfNeeded(
              pixels,
              pixels,
              local != null
                  ? MemoryImage(local)
                  : imageFactory(url!, avatarCacheKey(userId, url)),
            ),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            gaplessPlayback: true,
            frameBuilder: (_, child, frame, synchronous) => synchronous
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: child,
                  ),
            // The initial underneath is the fallback; a failed photo just
            // leaves it showing.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ],
      );
    }
    final corner = cornerRadius;
    return SizedBox(
      width: size,
      height: size,
      child: corner == null
          ? ClipOval(child: fill)
          : ClipRRect(borderRadius: BorderRadius.circular(corner), child: fill),
    );
  }
}
