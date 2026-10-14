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
}

final profileEditorActionsProvider = Provider<ProfileEditorActions>(
  ProfileEditorActions.new,
);
