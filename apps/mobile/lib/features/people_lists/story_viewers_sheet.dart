import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../shared/person_avatar.dart';
import '../settings.dart' show timeAgo;
import 'paged_list.dart';
import 'people_lists_actions.dart';
import 'story_time.dart';

/// Who watched one of your stories, most recent first.
class StoryViewersSheet extends ConsumerStatefulWidget {
  final Story story;
  final void Function(String userId) onOpen;
  const StoryViewersSheet({
    super.key,
    required this.story,
    required this.onOpen,
  });
  @override
  ConsumerState<StoryViewersSheet> createState() => _StoryViewersState();
}

class _StoryViewersState extends ConsumerState<StoryViewersSheet> {
  late final PagedList<Connection> list;

  @override
  void initState() {
    super.initState();
    final actions = ref.read(peopleListsActionsProvider);
    list = PagedList(
      (cursor) => actions.storyViewers(widget.story.storyId, cursor),
    )..load();
  }

  @override
  void dispose() {
    list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: .7,
    child: ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final Widget body;
        if (!list.loaded && list.loading) {
          body = const Center(child: CircularProgressIndicator());
        } else if (list.error != null && list.items.isEmpty) {
          body = Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Couldn’t load viewers.'),
                TextButton(
                  key: const Key('viewers-retry'),
                  onPressed: list.load,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        } else if (list.items.isEmpty) {
          body = const Center(
            key: Key('viewers-empty'),
            child: Text('No views yet.'),
          );
        } else {
          body = ListView.builder(
            itemCount: list.items.length + (list.cursor != null ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == list.items.length) {
                return TextButton(
                  key: const Key('viewers-more'),
                  onPressed: list.more,
                  child: const Text('Show more'),
                );
              }
              final v = list.items[i];
              return ListTile(
                key: ValueKey('viewer-${v.user.userId}'),
                onTap: () => widget.onOpen(v.user.userId),
                leading: PersonAvatar(
                  name: v.user.name,
                  avatarUrl: v.user.avatarUrl,
                  userId: v.user.userId,
                  radius: 18,
                ),
                title: Text(v.user.name),
                subtitle: Text('@${v.user.username} · ${timeAgo(v.since)}'),
              );
            },
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Seen by ${widget.story.viewsLabel}',
                key: const Key('viewers-title'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Posted ${timeAgo(widget.story.createdAt)} · ${storyTimeLeft(widget.story.expiresAt)}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: body),
          ],
        );
      },
    ),
  );
}
