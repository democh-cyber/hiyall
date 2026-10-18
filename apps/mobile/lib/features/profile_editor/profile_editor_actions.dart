import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/avatar_upload.dart';
import '../../core/state.dart';

/// The server calls the profile editor makes. Reads [apiProvider] and the session at call
/// time, so a test's override or a session change is always honoured.
class ProfileEditorActions {
  final Ref _ref;
  ProfileEditorActions(this._ref);

  /// The signed-in session, or null when there is none.
  Session? get session => _ref.read(sessionProvider).asData?.value;

  /// Saves the form's fields. Throws when there is no session.
  Future<Profile> saveProfile(
    Profile current,
    Map<String, dynamic> patch,
  ) async => _ref
      .read(apiProvider)
      .updateProfile(_ref.read(sessionProvider).asData!.value!, current, patch);

  /// Sends the chosen photo and returns its media id, or null (see [AvatarUploadController]).
  Future<String?> uploadAvatar(
    AvatarUploadController upload,
    Session session,
  ) => upload.upload(_ref.read(apiProvider), session);

  /// Makes the profile screens read the newest profile again.
  void invalidateProfile() => _ref.invalidate(profileProvider);

  /// Makes [mediaId] the profile photo, or removes the photo when it is null.
  Future<Profile> setAvatar(
    Session session,
    Profile current,
    String? mediaId,
  ) => _ref.read(apiProvider).setAvatar(session, current, mediaId);

  /// The newest own profile: a change of the first gallery photo moves its version on.
  Future<Profile> readProfile(Session session) =>
      _ref.read(apiProvider).profile(session);

  Future<Gallery> gallery(Session session) =>
      _ref.read(apiProvider).gallery(session);

  Future<Gallery> addPhoto(Session session, String mediaId) =>
      _ref.read(apiProvider).addGalleryPhoto(session, mediaId);

  Future<Gallery> replacePhoto(Session session, String old, String mediaId) =>
      _ref.read(apiProvider).replaceGalleryPhoto(session, old, mediaId);

  Future<Gallery> deletePhoto(Session session, String mediaId) =>
      _ref.read(apiProvider).deleteGalleryPhoto(session, mediaId);

  Future<Gallery> reorderPhotos(Session session, List<String> mediaIds) =>
      _ref.read(apiProvider).reorderGallery(session, mediaIds);

  /// Saves the chosen field audiences (`aboutMe`, `hometown`, `personality`) with the newest
  /// privacy version, then makes the privacy screens read it again.
  Future<void> saveAudiences(Map<String, String> audiences) async {
    final session = this.session;
    if (session == null || audiences.isEmpty) return;
    final api = _ref.read(apiProvider);
    final privacy = await _ref.read(privacyProvider.future);
    try {
      await api.updatePrivacy(session, privacy, {'fieldAudiences': audiences});
    } finally {
      _ref.invalidate(privacyProvider);
    }
  }
}

final profileEditorActionsProvider = Provider<ProfileEditorActions>(
  ProfileEditorActions.new,
);
