import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'pulse7.dart';
import 'state.dart';
import 'topics.dart';

/// The two tabs of the Pulse feed and the stories above it: "following" (your circle) and "everyone"
/// (public). One choice drives both, so the posts and the stories always agree. Kept in memory only.
const pulseFollowing = 'following', pulseEveryone = 'everyone';

final pulseTabProvider = NotifierProvider<PulseTab, String>(PulseTab.new);

class PulseTab extends Notifier<String> {
  @override
  String build() => pulseFollowing;
  void set(String mode) => state = mode;
}

/// The topic chosen on one tab (null is "All"), remembered in memory while the app runs and never saved.
final pulseTopicProvider = NotifierProvider.family<PulseTopic, String?, String>(
  PulseTopic.new,
);

class PulseTopic extends Notifier<String?> {
  PulseTopic(this.mode);
  final String mode;
  @override
  String? build() => null;
  void set(String? topic) => state = topic;
}

/// The topics to offer: this build's own list, which is the server's (`GET /v1/topics` answers the same names; a
/// newer server's extra topic still shows, as plain text, on the posts that carry it). It asks nobody, so a
/// composer or a feed never waits on, or fails because of, a request for a list that does not change.
final topicListProvider = FutureProvider<List<String>>(
  (ref) async => topicNames,
);

class ExploreState {
  final List<ExploreStory> items;
  final String? nextCursor;
  final bool loadingMore;
  const ExploreState(this.items, {this.nextCursor, this.loadingMore = false});
}

/// The Everyone side of the stories: public stories from people outside your tray, a page at a time, narrowed
/// by the Everyone tab's topic.
final storyExploreProvider = AsyncNotifierProvider<StoryExplore, ExploreState>(
  StoryExplore.new,
  retry: apiReadRetry,
);

class StoryExplore extends AsyncNotifier<ExploreState> {
  int _epoch = 0;

  Session get _session => requireSession(ref);

  @override
  Future<ExploreState> build() async {
    _epoch++;
    final topic = ref.watch(pulseTopicProvider(pulseEveryone));
    final page = await ref
        .watch(pulse7Provider)
        .storyExplore(requireSession(ref), topic: topic);
    return ExploreState(page.items, nextCursor: page.nextCursor);
  }

  Future<void> refresh() async {
    final topic = ref.read(pulseTopicProvider(pulseEveryone));
    final page = await ref
        .read(pulse7Provider)
        .storyExplore(_session, topic: topic);
    _epoch++;
    state = AsyncData(ExploreState(page.items, nextCursor: page.nextCursor));
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || current.nextCursor == null || current.loadingMore) {
      return;
    }
    final epoch = _epoch;
    state = AsyncData(
      ExploreState(
        current.items,
        nextCursor: current.nextCursor,
        loadingMore: true,
      ),
    );
    try {
      final topic = ref.read(pulseTopicProvider(pulseEveryone));
      final page = await ref
          .read(pulse7Provider)
          .storyExplore(_session, topic: topic, cursor: current.nextCursor);
      if (epoch != _epoch) return;
      final latest = state.asData?.value ?? current;
      final seen = {for (final e in latest.items) e.story.storyId};
      state = AsyncData(
        ExploreState([
          ...latest.items,
          ...page.items.where((e) => !seen.contains(e.story.storyId)),
        ], nextCursor: page.nextCursor),
      );
    } catch (_) {
      if (epoch == _epoch) {
        state = AsyncData(
          ExploreState(current.items, nextCursor: current.nextCursor),
        );
      }
      rethrow;
    }
  }
}
