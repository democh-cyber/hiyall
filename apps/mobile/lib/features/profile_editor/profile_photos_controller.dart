import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api.dart';
import '../../core/avatar_upload.dart';
import '../../core/profile_limits.dart';
import 'profile_editor_actions.dart';

/// The member's photo gallery inside the editor: up to [max] photos, the first one the profile photo. A photo
/// goes through the same pipeline as every other: pick, send to storage, the server scans and re-encodes it,
/// then it is added (or put in the place of another). Reordering and deleting are server calls too; the list
/// shown is always what the server last said, so the editor never disagrees with the profile.
class ProfilePhotosController extends ChangeNotifier {
  final ProfileEditorActions _actions;
  final AvatarUploadController upload;

  /// Called after the first photo changed, so the profile photo at the top of the editor and the profile screens
  /// read the newest profile.
  final VoidCallback onProfilePhotoChanged;
  ProfilePhotosController(
    this._actions,
    ImagePicker picker, {
    required this.onProfilePhotoChanged,
  }) : upload = AvatarUploadController(picker) {
    upload.addListener(_changed);
  }

  List<GalleryPhoto> photos = const [];
  int max = defaultMaxPhotos;
  bool loaded = false, loading = false, working = false;

  /// The id of the photo being replaced while its replacement is chosen and sent.
  String? replacing;
  String? error;
  bool _disposed = false;

  bool get full => photos.length >= max;
  bool get busy => working || upload.uploading;
  String? get failure => upload.error?.message ?? error;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    upload.dispose();
    super.dispose();
  }

  void clearError() {
    error = null;
    upload.error = null;
    _changed();
  }

  Future<void> load() async {
    final session = _actions.session;
    if (session == null || loading) return;
    loading = true;
    _changed();
    try {
      _take(await _actions.gallery(session));
      loaded = true;
    } on ApiFailure catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Your photos didn’t load. Try again.';
    } finally {
      loading = false;
      _changed();
    }
  }

  void _take(Gallery gallery) {
    final first = photos.isEmpty ? null : photos.first.mediaId;
    photos = gallery.photos;
    max = gallery.max;
    if (loaded && first != (photos.isEmpty ? null : photos.first.mediaId)) {
      onProfilePhotoChanged();
    }
  }

  /// Picks a photo and adds it, or puts it in the place of [replace].
  Future<void> pick(AvatarSource source, {String? replace}) async {
    final session = _actions.session;
    if (session == null || busy) return;
    if (replace == null && full) {
      error = 'You have $max photos. Remove one to add another.';
      _changed();
      return;
    }
    error = null;
    final picked = await upload.pick(source);
    if (picked == null) return;
    replacing = replace;
    working = true;
    _changed();
    try {
      final id = await _actions.uploadAvatar(upload, session);
      if (id == null || _disposed) return;
      _take(
        replace == null
            ? await _actions.addPhoto(session, id)
            : await _actions.replacePhoto(session, replace, id),
      );
      upload.clear();
    } on ApiFailure catch (e) {
      error = _words(e);
    } catch (_) {
      error = 'That photo didn’t upload. Try again.';
    } finally {
      replacing = null;
      working = false;
      _changed();
    }
  }

  /// A photo the server will not take is described without saying why.
  String _words(ApiFailure e) => switch (e.code) {
    'PHOTOS_FULL' => 'You have $max photos. Remove one to add another.',
    'VALIDATION' ||
    'UPLOAD_REJECTED' => 'That photo can’t be used. Try another one.',
    _ => e.displayMessage,
  };

  /// Retries the add after a failed attempt, without choosing the photo again.
  Future<void> retry() async {
    final session = _actions.session;
    if (session == null || upload.photo == null || busy) return;
    working = true;
    error = null;
    _changed();
    try {
      final id = await _actions.uploadAvatar(upload, session);
      if (id == null || _disposed) return;
      _take(
        replacing == null
            ? await _actions.addPhoto(session, id)
            : await _actions.replacePhoto(session, replacing!, id),
      );
      upload.clear();
    } on ApiFailure catch (e) {
      error = _words(e);
    } finally {
      working = false;
      _changed();
    }
  }

  Future<void> _run(Future<Gallery> Function(Session session) call) async {
    final session = _actions.session;
    if (session == null || busy) return;
    working = true;
    error = null;
    _changed();
    try {
      _take(await call(session));
    } on ApiFailure catch (e) {
      error = _words(e);
    } catch (_) {
      error = 'That didn’t work. Try again.';
    } finally {
      working = false;
      _changed();
    }
  }

  Future<void> delete(String mediaId) =>
      _run((s) => _actions.deletePhoto(s, mediaId));

  /// Moves a photo to [to] (0 is the profile photo).
  Future<void> move(String mediaId, int to) {
    final ids = [for (final p in photos) p.mediaId];
    final from = ids.indexOf(mediaId);
    if (from < 0 || to < 0 || to >= ids.length || to == from) {
      return Future.value();
    }
    ids
      ..removeAt(from)
      ..insert(to, mediaId);
    return _run((s) => _actions.reorderPhotos(s, ids));
  }
}
