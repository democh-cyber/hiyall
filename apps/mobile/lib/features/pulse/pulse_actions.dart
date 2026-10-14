import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/state.dart';

/// Every server call the Pulse widgets (posts, comments, stories) make, so a
/// widget holds its screen logic and guards, not the session lookup.
///
/// Reads [apiProvider] and the session through [Ref] at call time, so a test
/// that overrides the API with a fake is honoured.
class PulseActions {
  final Ref _ref;
  PulseActions(this._ref);

  /// True while someone is signed in. Widgets that skip an action when
  /// signed out ask this before awaiting.
  bool get hasSession => _ref.read(sessionProvider).asData?.value != null;

  Session get _session {
    final session = _ref.read(sessionProvider).asData?.value;
    if (session == null) throw const ApiFailure('Sign in to continue.');
    return session;
  }

  ApiClient get _api => _ref.read(apiProvider);

  Future<ApiPage<PostComment>> comments(String postId, String? cursor) async =>
      _api.comments(_session, postId, cursor);

  Future<PostComment> addComment(
    String postId,
    String text, {
    String? parentId,
  }) async => _api.addComment(_session, postId, text, parentId: parentId);

  Future<void> deleteComment(String commentId) async =>
      _api.deleteComment(_session, commentId);

  Future<void> deletePost(String postId) async =>
      _api.deletePost(_session, postId);

  Future<void> setMuted(String userId, bool muted) async =>
      _api.setMuted(_session, userId, muted);

  Future<Post> createPost({
    required String body,
    required String audience,
    required List<String> mediaIds,
  }) async => _api.createPost(
    _session,
    body: body,
    audience: audience,
    mediaIds: mediaIds,
  );

  Future<String> uploadPhoto(
    Uint8List bytes, {
    required String contentType,
    required String purpose,
    void Function(double progress)? onProgress,
  }) async => _api.uploadPhoto(
    _session,
    bytes,
    contentType: contentType,
    purpose: purpose,
    onProgress: onProgress,
  );

  Future<void> viewStory(String storyId) async =>
      _api.viewStory(_session, storyId);

  Future<void> deleteStory(String storyId) async =>
      _api.deleteStory(_session, storyId);

  Future<ApiPage<Map<String, dynamic>>> storyViewers(String storyId) async =>
      _api.storyViewers(_session, storyId);
}

final pulseActionsProvider = Provider<PulseActions>(PulseActions.new);
