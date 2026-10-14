import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/state.dart';
import '../../core/user_error.dart';
import '../../shared/person_link.dart';
import '../../shared/widgets.dart';
import '../settings.dart' show timeAgo;
import 'list_page.dart';
import 'message_person.dart';
import 'paged_list.dart';
import 'people_lists_actions.dart';

/// Who opened your profile, newest first visit first, for you alone. It says
/// plainly that visits are visible, so no one is listed by surprise.
class VisitorsScreen extends ConsumerStatefulWidget {
  const VisitorsScreen({super.key});
  @override
  ConsumerState<VisitorsScreen> createState() => _VisitorsState();
}

class _VisitorsState extends ConsumerState<VisitorsScreen> {
  /// What the screen tells everyone who opens it; the same is in the docs.
  static const note = 'People can see that you visited their profile.';
  late final PagedList<Visitor> list;
  final busy = <String>{};
  PeopleListsActions get actions => ref.read(peopleListsActionsProvider);

  @override
  void initState() {
    super.initState();
    list = PagedList((cursor) => actions.visitors(cursor))..load();
  }

  @override
  void dispose() {
    list.dispose();
    super.dispose();
  }

  Future<void> follow(Visitor v) async {
    final id = v.user.userId;
    if (!busy.add(id)) return;
    try {
      final state = await actions.follow(id);
      list.replaceWhere(
        (i) => i.user.userId == id,
        (i) => i.withFollowing(state),
      );
      ref.invalidate(profileProvider);
      ref.invalidate(otherProfileProvider(id));
      if (mounted) {
        showMessage(
          context,
          state == 'pending'
              ? 'Follow request sent.'
              : 'You follow ${v.user.name} now.',
        );
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      busy.remove(id);
    }
  }

  Future<void> block(Visitor v) async {
    if (!await confirmAction(
      context,
      title: 'Block ${v.user.name}?',
      body: 'They won’t be able to find your profile, follow you or message you. Your follows and friendship end, and your chat closes. They won’t be told.',
      action: 'Block',
    )) {
      return;
    }
    final id = v.user.userId;
    try {
      await actions.block(id);
      list.removeWhere((i) => i.user.userId == id);
      ref.invalidate(profileProvider);
      ref.invalidate(otherProfileProvider(id));
      if (mounted) showMessage(context, 'Account blocked.');
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Widget row(Visitor v) {
    final id = v.user.userId;
    return Stack(
      key: ValueKey('visitor-$id'),
      alignment: AlignmentDirectional.topEnd,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 48),
          child: PersonRow(
            person: v.user,
            subtitle:
                '@${v.user.username} · visited ${timeAgo(v.firstVisitedAt)}',
            onOpen: () => openPerson(context, id),
          ),
        ),
        PopupMenuButton<String>(
          key: Key('visitor-menu-$id'),
          tooltip: 'More for ${v.user.name}',
          onSelected: (choice) {
            switch (choice) {
              case 'message':
                messagePerson(context, ref, id, v.user.name);
              case 'follow':
                follow(v);
              case 'block':
                block(v);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              key: Key('visitor-message-$id'),
              value: 'message',
              child: const Text('Message'),
            ),
            PopupMenuItem(
              key: Key('visitor-follow-$id'),
              value: 'follow',
              enabled: v.following == 'none',
              child: Text(switch (v.following) {
                'active' => 'Following',
                'pending' => 'Follow requested',
                _ => 'Follow',
              }),
            ),
            PopupMenuItem(
              key: Key('visitor-block-$id'),
              value: 'block',
              child: Text(
                'Block',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListPage<Visitor>(
    title: 'Visitors',
    backLabel: 'Profile',
    backTo: '/profile',
    list: list,
    header: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          note,
          key: const Key('visitors-note'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
    ],
    row: row,
    empty: const EmptyCard(
      icon: Icons.visibility_outlined,
      title: 'No visitors yet',
      description: 'When someone opens your profile, they show up here.',
    ),
  );
}
