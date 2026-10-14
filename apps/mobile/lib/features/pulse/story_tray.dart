import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/feed_state.dart';
import '../../core/state.dart';
import '../../shared/press_scale.dart';
import 'story_bubble.dart';
import 'story_viewer.dart';

/// Stories from the viewer's circle, own first, with a way to add one.
class StoryTray extends ConsumerWidget {
  const StoryTray({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups =
        ref.watch(storyTrayProvider).asData?.value ?? const <StoryGroup>[];
    final mine = groups.where((g) => g.mine).firstOrNull;
    final others = [
      for (final g in groups)
        if (!g.mine) g,
    ];
    final viewable = [?mine, ...others];
    final profile = ref.watch(profileProvider).asData?.value;
    void open(StoryGroup g) =>
        openStories(context, viewable, viewable.indexOf(g));
    // Labels may grow with the reader's text size, up to 1.4×.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: SizedBox(
        height: 104 + scaler.scale(17),
        child: ScrollConfiguration(
          behavior: const DragAnywhereBehavior(),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 1 + others.length,
            itemBuilder: (context, i) {
              if (i == 0) {
                return StoryBubble(
                  key: const Key('story-mine'),
                  name: profile?.displayName ?? 'You',
                  userId: profile?.userId ?? '',
                  avatarUrl: profile?.avatarUrl,
                  label: 'Your story',
                  ring: mine == null ? StoryRing.none : StoryRing.unseen,
                  add: true,
                  onTap: mine == null
                      ? () => context.push('/story/new')
                      : () => open(mine),
                  onAdd: () => context.push('/story/new'),
                );
              }
              final g = others[i - 1];
              return StoryBubble(
                key: Key('story-${g.author.userId}'),
                name: g.author.name,
                userId: g.author.userId,
                avatarUrl: g.author.avatarUrl,
                label: g.author.name,
                ring: g.allSeen ? StoryRing.seen : StoryRing.unseen,
                onTap: () => open(g),
              );
            },
          ),
        ),
      ),
    );
  }
}

void openStories(BuildContext context, List<StoryGroup> groups, int start) {
  if (groups.isEmpty || start < 0) return;
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => StoryViewer(groups: groups, start: start),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}
