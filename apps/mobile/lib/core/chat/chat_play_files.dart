import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The short-lived plaintext files the platform needs: a recording while it is made and before it is sealed,
/// and a voice message or video while it plays (the audio and video players read files, not memory). They live
/// in the app-private `chat_play` folder (never the gallery, never shared storage), are deleted as soon as they
/// are not needed (the recording once its bytes are read, a played file when the player lets go of it), and
/// every one still there is deleted when the chat starts and on sign-out. The longest one is on the phone
/// for as long as the message plays.
class PlayFiles {
  PlayFiles(this.dir, {Random? random}) : _random = random ?? Random.secure();
  final Directory dir;
  final Random _random;

  String _name(String ext) {
    final id = List.generate(
      12,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$id.$ext';
  }

  /// A new, empty path for the recorder to write to.
  Future<File> reserve(String ext) async {
    await dir.create(recursive: true);
    return File('${dir.path}/${_name(ext)}');
  }

  /// Writes [bytes] to a new file and returns it.
  Future<File> write(Uint8List bytes, String ext) async {
    final file = await reserve(ext);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> delete(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Removed by the start-up sweep at the latest.
    }
  }

  /// Deletes everything in the folder; called when the chat starts.
  Future<void> purge() async {
    try {
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          try {
            await entry.delete(recursive: true);
          } on FileSystemException {
            // Best effort.
          }
        }
      }
    } on FileSystemException {
      // Nothing to sweep.
    }
  }

  Future<int> count() async {
    if (!await dir.exists()) return 0;
    return dir.list().length;
  }
}
