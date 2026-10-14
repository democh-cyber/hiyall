import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api.dart';
import '../../core/avatar_upload.dart';
import 'profile_editor_actions.dart';

/// The profile photo flow inside the editor: pick, upload, attach, remove. Notifies on every
/// change, so the form rebuilds the way it does for its own state.
class ProfileAvatarController extends ChangeNotifier {
  final ProfileEditorActions _actions;
  final AvatarUploadController upload;

  /// Shows a short message to the person; the form decides whether it is still on screen.
  final void Function(String message) onMessage;

  /// The profile as last seen by this form. A photo change moves its version
  /// on, and the next Save must carry that version.
  Profile current;
  bool attaching = false;
  String? error, uploadedId;
  bool _disposed = false;

  ProfileAvatarController(
    this._actions,
    ImagePicker picker,
    this.current, {
    required this.onMessage,
  }) : upload = AvatarUploadController(picker) {
    upload.addListener(_changed);
  }

  bool get working => upload.uploading || attaching;

  /// The message to show under the photo, if any.
  String? get failure => upload.error?.message ?? error;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// The same version again means our own photo change was read back; take
  /// it for its fresh photo URLs. A different one is someone else's edit, and
  /// is left to the conflict path so their changes aren't overwritten.
  void adopt(Profile profile) {
    if (profile.version == current.version) current = profile;
  }

  void clearError() {
    error = null;
    _changed();
  }

  /// Picks a photo from [source] and, when one was chosen, sends it.
  Future<void> pick(AvatarSource source) async {
    final picked = await upload.pick(source);
    if (picked != null) {
      uploadedId = null;
      await send();
    }
  }

  /// Uploads the chosen photo, then makes it the profile photo. A failed
  /// attach keeps the upload, so trying again doesn't send the photo twice.
  Future<void> send() async {
    final session = _actions.session;
    if (session == null || upload.photo == null || working) return;
    error = null;
    _changed();
    final id = uploadedId ?? await _actions.uploadAvatar(upload, session);
    if (id == null || _disposed) return;
    uploadedId = id;
    attaching = true;
    _changed();
    try {
      current = await _actions.setAvatar(session, current, id);
      uploadedId = null;
      upload.clear();
      _actions.invalidateProfile();
      if (!_disposed) onMessage('Photo updated.');
    } on ApiFailure catch (failure) {
      if (!_disposed) {
        error = failure.message;
        _changed();
      }
    } finally {
      if (!_disposed) {
        attaching = false;
        _changed();
      }
    }
  }

  Future<void> remove() async {
    final session = _actions.session;
    if (session == null) return;
    uploadedId = null;
    upload.clear();
    if (current.avatarUrl == null) return;
    attaching = true;
    _changed();
    try {
      current = await _actions.setAvatar(session, current, null);
      _actions.invalidateProfile();
      if (!_disposed) onMessage('Photo removed.');
    } on ApiFailure catch (failure) {
      if (!_disposed) {
        error = failure.message;
        _changed();
      }
    } finally {
      if (!_disposed) {
        attaching = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    upload.dispose();
    super.dispose();
  }
}
