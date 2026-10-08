import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'state.dart';

class FeedState {
  final List<Post> items;
  final String? nextCursor;
  final bool loadingMore;
  const FeedState(this.items, {this.nextCursor, this.loadingMore = false});
  FeedState copyWith({
    List<Post>? items,
    String? Function()? nextCursor,
    bool? loadingMore,
  }) => FeedState(
    items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// Pulse, a page at a time. The argument is the mode: "following" (your
/// circle) or "everyone" (recent public posts). Reactions and saves change
/// locally first and roll back if the server refuses.
final feedProvider =
    AsyncNotifierProvider.family<FeedController, FeedState, String>(
      FeedController.new,
      retry: apiReadRetry,
    );

class FeedController extends AsyncNotifier<FeedState> {
  FeedController(this.mode);
  final String mode;

  ApiClient get _api => ref.read(apiProvider);
  Session get _session => requireSession(ref);

  @override
  Future<FeedState> build() async {
    final page = await ref.watch(apiProvider).feed(requireSession(ref), mode);
    return FeedState(page.items, nextCursor: page.nextCursor);
  }

  Future<void> refresh() async {
    final page = await _api.feed(_session, mode);
    state = AsyncData(FeedState(page.items, nextCursor: page.nextCursor));
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || current.nextCursor == null || current.loadingMore) {
      return;
    }
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _api.feed(_session, mode, current.nextCursor);
      final seen = {for (final p in current.items) p.postId};
      state = AsyncData(
        current.copyWith(
          items: [
            ...current.items,
            ...page.items.where((p) => !seen.contains(p.postId)),
          ],
          nextCursor: () => page.nextCursor,
          loadingMore: false,
        ),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(loadingMore: false));
      rethrow;
    }
  }

  void _replace(String id, Post Function(Post) change) {
    final current = state.asData?.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        items: [for (final p in current.items) p.postId == id ? change(p) : p],
      ),
    );
  }

  Post? _find(String id) =>
      state.asData?.value.items.where((p) => p.postId == id).firstOrNull;

  /// Sets, changes or (with null) clears the viewer's reaction.
  Future<void> react(String id, String? reaction) async {
    final before = _find(id);
    if (before == null || before.myReaction == reaction) return;
    final delta =
        (reaction == null ? -1 : 0) + (before.myReaction == null ? 1 : 0);
    _replace(
      id,
      (p) => p.copyWith(
        myReaction: () => reaction,
        reactionCount: (p.reactionCount + delta).clamp(0, 1 << 30),
      ),
    );
    try {
      await _api.react(_session, id, reaction);
    } catch (_) {
      _replace(id, (_) => before);
      rethrow;
    }
  }

  Future<void> toggleSave(String id) async {
    final before = _find(id);
    if (before == null) return;
    _replace(id, (p) => p.copyWith(saved: !p.saved));
    try {
      await _api.setPostSaved(_session, id, !before.saved);
    } catch (_) {
      _replace(id, (_) => before);
      rethrow;
    }
  }

  /// Shows a post the viewer just made at the top.
  void prepend(Post post) {
    final current = state.asData?.value;
    if (current == null || current.items.any((p) => p.postId == post.postId)) {
      return;
    }
    state = AsyncData(current.copyWith(items: [post, ...current.items]));
  }

  void remove(String id) {
    final current = state.asData?.value;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(
        items: [
          for (final p in current.items)
            if (p.postId != id) p,
        ],
      ),
    );
  }

  void commentCountChanged(String id, int delta) => _replace(
    id,
    (p) => p.copyWith(commentCount: (p.commentCount + delta).clamp(0, 1 << 30)),
  );
}

/// Active stories from the viewer's circle, own first.
final storyTrayProvider = FutureProvider<List<StoryGroup>>(
  (ref) => ref.watch(apiProvider).storyTray(requireSession(ref)),
  retry: apiReadRetry,
);
