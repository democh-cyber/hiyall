import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hiyall/shared/person_avatar.dart';

/// A small valid JPEG-looking header; enough for the type check, never decoded.
final jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

/// A 1x1 PNG, for previews that really decode.
final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Hands back one chosen photo, or fails the way the platform plugin does.
class PhotoPicker extends ImagePicker {
  Uint8List? bytes = jpegBytes;
  Object? failure;
  final sources = <ImageSource>[];
  double? maxWidth;
  int? quality;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    sources.add(source);
    this.maxWidth = maxWidth;
    quality = imageQuality;
    if (failure != null) throw failure!;
    return bytes == null ? null : XFile.fromData(bytes!, name: 'photo.jpg');
  }
}

PlatformException photoAccessDenied() =>
    PlatformException(code: 'photo_access_denied');

/// An image that is already decoded, so widgets show it without real I/O.
class StaticImage extends ImageProvider<StaticImage> {
  final ui.Image image;
  const StaticImage(this.image);
  @override
  Future<StaticImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    StaticImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture(ImageInfo(image: image.clone())),
  );
}

/// An image that never loads.
class BrokenImage extends ImageProvider<BrokenImage> {
  const BrokenImage();
  @override
  Future<BrokenImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    BrokenImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Future<ImageInfo>.error(Exception('x')));
}

/// Swaps the network avatar loader for [make] and records what was asked for.
/// Call [restore] in a tearDown.
class AvatarRequests {
  final urls = <String>[];
  final keys = <String>[];
  AvatarRequests(ImageProvider Function() make) {
    PersonAvatar.imageFactory = (url, key) {
      urls.add(url);
      keys.add(key);
      return make();
    };
  }
  static void restore() => PersonAvatar.imageFactory = _original;
  static final _original = PersonAvatar.imageFactory;
}
