import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:path_provider/path_provider.dart';

/// Photos picked from the gallery or taken with the camera.
///
/// `image_picker` hands the app a plaintext COPY of every pick in a temporary folder and never removes it:
/// on Android `<cacheDir>/<uuid>/<name>` (the copy of a gallery pick), `<cacheDir>/scaled_<name>` (the
/// resized one, which is the file the app gets when it asks for a maximum size) and
/// `<cacheDir>/<uuid><digits>.jpg` (a camera capture); on iOS `<tmp>/image_picker_<id>.<ext>`. A photo that
/// was meant for an end-to-end encrypted chat would sit there for as long as the system leaves it. So:
///
/// - every place that picks a photo reads it with [readAndDeletePick], which deletes the file once its bytes
///   are in memory;
/// - [sweepPickerTemp] removes whatever is left (the original of a resized pick, a pick that was never read),
///   at every launch and at every sign-out.

/// Reads [file] and deletes it (and the `<uuid>` folder it sits in, once empty), whatever the read does.
/// Deleting never fails the read.
Future<Uint8List> readAndDeletePick(XFile file) async {
  try {
    return await file.readAsBytes();
  } finally {
    await deletePickedFile(file.path);
  }
}

/// Deletes the picked file at [path]; best effort. On the web there is no file to delete.
Future<void> deletePickedFile(String path) async {
  if (path.isEmpty) return; // a pick held in memory has no file behind it
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
    final parent = f.parent;
    if (_uuid.hasMatch(_name(parent.path)) && await _isEmpty(parent)) {
      await parent.delete();
    }
  } catch (_) {
    // A file the system will not let go of is swept at the next launch or sign-out.
  }
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Android camera capture: a UUID followed by digits, `.jpg` (File.createTempFile(uuid, ".jpg")).
final _androidCapture = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\d*\.(jpe?g|mp4)$',
  caseSensitive: false,
);

const _mediaExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'heic',
  'heif',
  'mp4',
  'mov',
};

String _name(String path) => path.split(Platform.pathSeparator).last;

bool _isMedia(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 &&
      _mediaExtensions.contains(name.substring(dot + 1).toLowerCase());
}

Future<bool> _isEmpty(Directory dir) async => await dir.list().isEmpty;

/// Whether [entry], found directly in a temporary folder, is something `image_picker` left.
Future<bool> _isPickerLeftover(FileSystemEntity entry) async {
  final name = _name(entry.path);
  if (entry is File) {
    return name.startsWith('image_picker_') ||
        (name.startsWith('scaled_') && _isMedia(name)) ||
        _androidCapture.hasMatch(name);
  }
  if (entry is Directory && _uuid.hasMatch(name)) {
    // A `<uuid>` folder holding nothing but pictures (or nothing): the shape of a gallery pick's copy. Any
    // other content means it is somebody else's folder.
    try {
      await for (final inner in entry.list()) {
        if (inner is! File || !_isMedia(_name(inner.path))) return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }
  return false;
}

/// Removes everything `image_picker` left in [roots] (default: the app's temporary folder, which is
/// `cacheDir` on Android, and the system temporary folder, which is `tmp` on iOS). Looks only at the first
/// level of each folder, and only at the shapes listed above; never throws. Returns how many entries went.
Future<int> sweepPickerTemp({List<Directory>? roots}) async {
  final folders = roots ?? await _defaultRoots();
  var removed = 0;
  final seen = <String>{};
  for (final dir in folders) {
    if (!seen.add(dir.absolute.path)) continue;
    try {
      if (!await dir.exists()) continue;
      for (final entry in await dir.list().toList()) {
        try {
          if (!await _isPickerLeftover(entry)) continue;
          await entry.delete(recursive: true);
          removed++;
        } on FileSystemException {
          // In use or already gone; the next sweep tries again.
        }
      }
    } catch (_) {
      // An unreadable folder has nothing this can remove.
    }
  }
  return removed;
}

Future<List<Directory>> _defaultRoots() async {
  final folders = <Directory>[];
  try {
    folders.add(await getTemporaryDirectory());
  } catch (_) {
    // No plugin (a test) or no folder: only the system one.
  }
  try {
    folders.add(Directory.systemTemp);
  } catch (_) {}
  return folders;
}

/// The launch and sign-out sweep. Not awaited by the sign-out hook (like the image caches' wipe): signing
/// out has no reason to wait for the disk, and the sweep only touches the picker's own leftovers, so a sweep
/// still running when the process ends is finished by the one at the next launch. Replaced by a fake in tests.
final pickerTempSweepProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    unawaited(sweepPickerTemp().then<void>((_) {}, onError: (_) {}));
  },
);
