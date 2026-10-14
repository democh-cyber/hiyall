import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/state.dart';

/// Every server call the people lists (followers, following, visitors, my
/// stories, story viewers) make, so a screen holds its own logic and guards,
/// not the session lookup.
///
/// Reads [apiProvider] and the session through [Ref] at call time, so a test
/// that overrides the API with a fake is honoured.
class PeopleListsActions {
  final Ref _ref;
  PeopleListsActions(this._ref);

  /// True while someone is signed in.
  bool get hasSession => _ref.read(sessionProvider).asData?.value != null;

  Session get _session {
    final session = _ref.read(sessionProvider).asData?.value;
    if (session == null) throw const ApiFailure('Sign in to continue.');
    return session;
  }

  ApiClient get _api => _ref.read(apiProvider);

  Future<ApiPage<Connection>> connections(
    String kind, {
    String? userId,
    String? cursor,
  }) => _api.connections(_session, kind, userId: userId, cursor: cursor);

  Future<ApiPage<Connection>> followRequests(String? cursor) =>
      _api.followRequests(_session, cursor);

  Future<void> unfollow(String userId) => _api.unfollow(_session, userId);

  Future<void> removeFollower(String userId) =>
      _api.removeFollower(_session, userId);

  /// Returns the new follow state, `active` or `pending`.
  Future<String> follow(String userId) => _api.follow(_session, userId);

  Future<void> respondFollowRequest(String followerId, bool accept) =>
      _api.respondFollowRequest(_session, followerId, accept);

  Future<ApiPage<Visitor>> visitors(String? cursor) =>
      _api.visitors(_session, cursor);

  Future<void> block(String userId) => _api.block(_session, userId, true);

  Future<ApiPage<Story>> myStories(String? cursor) =>
      _api.myStories(_session, cursor);

  Future<void> deleteStory(String storyId) =>
      _api.deleteStory(_session, storyId);

  /// Who watched [storyId], read as people.
  Future<ApiPage<Connection>> storyViewers(
    String storyId,
    String? cursor,
  ) async {
    final page = await _api.storyViewers(_session, storyId, cursor);
    return ApiPage([
      for (final v in page.items) Connection.fromJson(v),
    ], page.nextCursor);
  }

  Future<ApiPage<Story>> userStories(String userId) =>
      _api.userStories(_session, userId);
}

final peopleListsActionsProvider = Provider<PeopleListsActions>(
  PeopleListsActions.new,
);
