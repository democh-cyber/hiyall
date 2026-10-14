import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/feed_state.dart';
import '../../core/state.dart';
import '../../core/user_error.dart';
import '../../shared/person_link.dart';
import '../../shared/widgets.dart';
import 'list_page.dart';
import 'paged_list.dart';
import 'people_lists_actions.dart';
import 'story_row.dart';
import 'story_viewers_sheet.dart';

/// Your active stories (they last up to 24 hours), newest first: who saw each, when
/// it goes, and a way to delete it or add another.
class MyStoriesScreen extends ConsumerStatefulWidget {
  const MyStoriesScreen({super.key});
  @override
  ConsumerState<MyStoriesScreen> createState() => _MyStoriesState();
}

class _MyStoriesState extends ConsumerState<MyStoriesScreen> {
  late final PagedList<Story> list;
  PeopleListsActions get actions => ref.read(peopleListsActionsProvider);

  @override
  void initState() {
    super.initState();
    list = PagedList((cursor) => actions.myStories(cursor))..load();
  }

  @override
  void dispose() {
    list.dispose();
    super.dispose();
  }

  Future<void> add() async {
    await context.push<void>('/story/new');
    if (!mounted) return;
    list.load();
    ref.invalidate(profileProvider);
  }

  Future<void> delete(Story story) async {
    if (!await confirmAction(
      context,
      title: 'Delete this story?',
      body: 'It disappears for everyone right away and can’t be brought back.',
      action: 'Delete',
    )) {
      return;
    }
    try {
      await actions.deleteStory(story.storyId);
      list.removeWhere((i) => i.storyId == story.storyId);
      ref.invalidate(profileProvider);
      ref.invalidate(storyTrayProvider);
      if (mounted) showMessage(context, 'Story deleted.');
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> viewers(Story story) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => StoryViewersSheet(
      story: story,
      onOpen: (id) {
        Navigator.pop(sheet);
        openPerson(context, id);
      },
    ),
  );

  Widget row(Story s) =>
      StoryRow(story: s, onOpen: () => viewers(s), onDelete: () => delete(s));

  @override
  Widget build(BuildContext context) => ListPage<Story>(
    title: 'My stories',
    backLabel: 'Profile',
    backTo: '/profile',
    list: list,
    trailing: FilledButton.icon(
      key: const Key('add-story'),
      onPressed: add,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('Add story'),
    ),
    header: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          'Stories last up to 24 hours. Tap one to see who watched it.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
    ],
    row: row,
    empty: EmptyCard(
      icon: Icons.auto_awesome_rounded,
      title: 'No stories up right now',
      description: 'Share a photo or a few words. It stays up for as long as you choose, up to 24 hours.',
      action: FilledButton(
        key: const Key('add-story-empty'),
        onPressed: add,
        child: const Text('Add story'),
      ),
    ),
  );
}
