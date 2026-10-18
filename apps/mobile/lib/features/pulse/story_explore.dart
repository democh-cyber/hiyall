import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pulse_tabs.dart';
import '../../core/user_error.dart';
import '../../shared/chat_tokens.dart';
import 'story_bubble.dart';
import '../../shared/press_scale.dart' show DragAnywhereBehavior;
import 'story_tray.dart' show openStories;

/// The "Everyone" side of the stories: public stories from people outside your tray, newest first, in the
/// same bubbles as the tray. A tap opens them in the story viewer, which carries on to the next one. It
/// narrows to the topic chosen on the Everyone tab, and asks for the next page near its end.
class StoryExploreStrip extends ConsumerWidget {
  const StoryExploreStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(storyExploreProvider);
    final t = ChatTokens.of(context);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);
    final height = 104 + scaler.scale(17);
    Widget message(String text, {VoidCallback? retry}) => SizedBox(
      height: 72,
      child: Center(
        child: retry == null
            ? Text(text, style: TextStyle(color: t.textSecondary))
            : TextButton(
                key: const Key('story-explore-retry'),
                onPressed: retry,
                child: Text(text),
              ),
      ),
    );
    return state.when(
      loading: () => SizedBox(
        height: height,
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => message(
        'Couldn’t load stories. Retry',
        retry: () => ref.invalidate(storyExploreProvider),
      ),
      data: (data) {
        if (data.items.isEmpty) {
          final topic = ref.watch(pulseTopicProvider(pulseEveryone));
          return message(
            topic == null
                ? 'No public stories right now.'
                : 'No public stories on this topic right now.',
          );
        }
        final groups = [for (final e in data.items) e.group];
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: SizedBox(
            height: height,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 240) {
                  ref.read(storyExploreProvider.notifier).loadMore().catchError(
                    (Object e) {
                      if (context.mounted) showFailure(context, e);
                    },
                  );
                }
                return false;
              },
              child: ScrollConfiguration(
                behavior: const DragAnywhereBehavior(),
                child: ListView.builder(
                  key: const Key('story-explore'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: data.items.length,
                  itemBuilder: (context, i) {
                    final e = data.items[i];
                    return StoryBubble(
                      key: Key('explore-${e.story.storyId}'),
                      name: e.author.name,
                      userId: e.author.userId,
                      avatarUrl: e.author.avatarUrl,
                      label: e.author.name,
                      ring: e.story.seen ? StoryRing.seen : StoryRing.unseen,
                      onTap: () => openStories(context, groups, i),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
