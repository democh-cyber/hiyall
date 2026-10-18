import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/pulse7.dart';
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

  Pulse7Client get _p7 => _ref.read(pulse7Provider);

  /// The top-level comments of a post, each with its reply count.
  Future<ApiPage<PostComment>> topComments(String postId, String? cursor) =>
      _p7.topComments(_session, postId, cursor);

  /// The replies to one comment.
  Future<ApiPage<PostComment>> replies(
    String postId,
    String commentId,
    String? cursor,
  ) => _p7.replies(_session, postId, commentId, cursor);

  /// Uploads a recorded voice note and returns it ready to attach.
  Future<VoiceUpload> uploadVoice(
    Uint8List bytes, {
    void Function(double progress)? onProgress,
  }) => _p7.uploadVoice(_session, bytes, onProgress: onProgress);

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
    String? topic,
    String? voiceMediaId,
  }) async => topic == null && voiceMediaId == null
      ? _api.createPost(
          _session,
          body: body,
          audience: audience,
          mediaIds: mediaIds,
        )
      : _p7.createPost(
          _session,
          body: body,
          audience: audience,
          mediaIds: mediaIds,
          topic: topic,
          voiceMediaId: voiceMediaId,
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
