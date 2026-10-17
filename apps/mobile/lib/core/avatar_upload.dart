import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'picked_file.dart';

/// The most the API accepts for one photo.
const maxPhotoBytes = 15 * 1024 * 1024;

/// The picker, replaced by a fake in tests.
final imagePickerProvider = Provider<ImagePicker>((ref) => ImagePicker());

/// Whether the device has a camera to offer; browsers and desktops pick files.
bool get canTakePhoto =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

enum AvatarProblem {
  tooLarge,
  unsupportedType,
  noPermission,
  network,
  quota,
  other,
}

/// Why a profile photo could not be chosen or uploaded, in words to show.
class AvatarError implements Exception {
  final AvatarProblem problem;
  final String message;
  const AvatarError(this.problem, this.message);

  /// Choosing a different photo is the only way out of these two.
  bool get needsAnotherPhoto =>
      problem == AvatarProblem.tooLarge ||
      problem == AvatarProblem.unsupportedType;

  /// Whether sending the same photo again could work now. A limit (the day's uploads or a full
  /// storage) will not lift by retrying at once, so it offers no retry.
  bool get canRetry => !needsAnotherPhoto && problem != AvatarProblem.quota;

  factory AvatarError.of(AvatarProblem problem) => AvatarError(
    problem,
    switch (problem) {
      AvatarProblem.tooLarge =>
        'That photo is too large. Choose one under 15 MB.',
      AvatarProblem.unsupportedType => 'Use a JPEG, PNG or WebP photo.',
      AvatarProblem.noPermission =>
        'Hiyall can’t reach your photos. Allow access in your device settings.',
      AvatarProblem.network =>
        'That photo didn’t upload. Check your connection and try again.',
      AvatarProblem.quota =>
        'You’ve reached today’s photo limit. Try again later.',
      AvatarProblem.other => 'Something went wrong with that photo. Try again.',
    },
  );

  /// Maps whatever a pick or upload threw. Never includes URLs.
  factory AvatarError.from(Object error) {
    if (error is AvatarError) return error;
    if (error is PlatformException) {
      return AvatarError.of(
        error.code.contains('access_denied')
            ? AvatarProblem.noPermission
            : AvatarProblem.other,
      );
    }
    // A limit speaks in the server's words (calm, with when it lifts), not as a connection problem.
    if (error is ApiFailure && error.code == 'QUOTA') {
      return AvatarError(AvatarProblem.quota, error.displayMessage);
    }
    if (error is ApiFailure) {
      return AvatarError.of(switch (error.code) {
        'TOO_LARGE' => AvatarProblem.tooLarge,
        'UNSUPPORTED_MEDIA' => AvatarProblem.unsupportedType,
        _ =>
          error.status == null || error.status! >= 500 || error.status == 429
              ? AvatarProblem.network
              : AvatarProblem.other,
      });
    }
    return AvatarError.of(AvatarProblem.other);
  }
  @override
  String toString() => message;
}

/// A profile photo chosen on this device, held in memory until it is sent.
class AvatarPhoto {
  final Uint8List bytes;
  final String contentType;
  const AvatarPhoto(this.bytes, this.contentType);
}

enum AvatarSource { gallery, camera }

/// Choosing and uploading one profile photo. It holds the picked bytes so the
/// screen can preview them at once, and keeps them after a failed upload so
/// trying again doesn't mean choosing again. Nothing here touches the profile:
/// the caller attaches the returned media id with [ApiClient.setAvatar].
class AvatarUploadController extends ChangeNotifier {
  final ImagePicker picker;
  AvatarUploadController(this.picker);

  AvatarPhoto? photo;
  AvatarError? error;
  bool uploading = false;
  double progress = 0;
  int _attempt = 0;
  bool _disposed = false;

  /// Opens the gallery or camera. Null when the person backed out; on a
  /// refused photo [error] says why and the previous choice is kept.
  Future<AvatarPhoto?> pick(AvatarSource source) async {
    try {
      final file = await picker.pickImage(
        source: source == AvatarSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (file == null) return null;
      final bytes = await readAndDeletePick(file);
      unawaited(sweepPickerTemp());
      final type = sniffImageType(bytes);
      if (type == null) throw AvatarError.of(AvatarProblem.unsupportedType);
      if (bytes.length > maxPhotoBytes) {
        throw AvatarError.of(AvatarProblem.tooLarge);
      }
      photo = AvatarPhoto(bytes, type);
      error = null;
      _notify();
      return photo;
    } catch (e) {
      error = AvatarError.from(e);
      _notify();
      return null;
    }
  }

  /// Sends the chosen photo and returns its media id, or null after setting
  /// [error] (or when [clear] ended it first). Call again to retry.
  Future<String?> upload(ApiClient api, Session session) async {
    final chosen = photo;
    if (chosen == null || uploading) return null;
    final attempt = ++_attempt;
    uploading = true;
    progress = 0;
    error = null;
    _notify();
    try {
      final id = await api.uploadPhoto(
        session,
        chosen.bytes,
        contentType: chosen.contentType,
        purpose: 'avatar',
        onProgress: (v) {
          if (attempt != _attempt) return;
          progress = v;
          _notify();
        },
      );
      return attempt == _attempt ? id : null;
    } catch (e) {
      if (attempt == _attempt) error = AvatarError.from(e);
      return null;
    } finally {
      if (attempt == _attempt) {
        uploading = false;
        _notify();
      }
    }
  }

  /// Forgets the chosen photo and any message about it. It also cancels an
  /// upload in flight: the result is dropped, and bytes already sent are
  /// left to expire on the server unused.
  void clear() {
    _attempt++;
    photo = null;
    error = null;
    uploading = false;
    progress = 0;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
