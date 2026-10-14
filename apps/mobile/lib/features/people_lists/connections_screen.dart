import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/activity_state.dart';
import '../../core/api.dart';
import '../../core/state.dart';
import '../../core/user_error.dart';
import '../../shared/person_link.dart';
import '../../shared/widgets.dart';
import 'list_page.dart';
import 'message_person.dart';
import 'paged_list.dart';
import 'people_lists_actions.dart';

/// Who someone follows or who follows them, newest first. Your own can be
/// managed; another member's is read-only and only opens when they let you see
/// it, which the server decides on every request.
class ConnectionsScreen extends ConsumerStatefulWidget {
  /// `following` or `followers`.
  final String kind;

  /// Whose list; null is the signed-in member's own.
  final String? userId;
  const ConnectionsScreen({super.key, required this.kind, this.userId});
  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsState();
}

class _ConnectionsState extends ConsumerState<ConnectionsScreen> {
  late final PagedList<Connection> list;
  PagedList<Connection>? requests;
  final busy = <String>{};

  bool get own => widget.userId == null;
  bool get followers => widget.kind == 'followers';
  PeopleListsActions get actions => ref.read(peopleListsActionsProvider);

  @override
  void initState() {
    super.initState();
    list = PagedList(
      (cursor) => actions.connections(
        widget.kind,
        userId: widget.userId,
        cursor: cursor,
      ),
    )..load();
    if (own && followers) {
      requests = PagedList((cursor) => actions.followRequests(cursor))..load();
    }
  }

  @override
  void dispose() {
    list.dispose();
    requests?.dispose();
    super.dispose();
  }

  /// Runs [action] for one person; the row's buttons are off while it does.
  Future<void> run(String id, Future<void> Function() action) async {
    if (!busy.add(id)) return;
    setState(() {});
    try {
      await action();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      busy.remove(id);
      if (mounted) setState(() {});
    }
  }

  /// Counts on both profiles change with every connection.
  void refreshCounts(String otherId) {
    ref.invalidate(profileProvider);
    ref.invalidate(otherProfileProvider(otherId));
    ref.invalidate(activityProvider);
  }

  Future<void> unfollow(Connection c) async {
    if (!await confirmAction(
      context,
      title: 'Unfollow ${c.user.name}?',
      body: 'You can follow again any time.',
      action: 'Unfollow',
    )) {
      return;
    }
    await run(c.user.userId, () async {
      await actions.unfollow(c.user.userId);
      list.removeWhere((i) => i.user.userId == c.user.userId);
      refreshCounts(c.user.userId);
      if (mounted) showMessage(context, 'Unfollowed ${c.user.name}.');
    });
  }

  Future<void> removeFollower(Connection c) async {
    if (!await confirmAction(
      context,
      title: 'Remove ${c.user.name} as a follower?',
      body: 'They’ll stop following you and won’t be told. They can follow you again unless you block them.',
      action: 'Remove',
    )) {
      return;
    }
    await run(c.user.userId, () async {
      await actions.removeFollower(c.user.userId);
      list.removeWhere((i) => i.user.userId == c.user.userId);
      refreshCounts(c.user.userId);
      if (mounted) showMessage(context, 'Removed ${c.user.name}.');
    });
  }

  Future<void> followBack(Connection c) => run(c.user.userId, () async {
    final state = await actions.follow(c.user.userId);
    list.replaceWhere(
      (i) => i.user.userId == c.user.userId,
      (i) => i.withFollowing(state),
    );
    refreshCounts(c.user.userId);
    if (mounted) {
      showMessage(
        context,
        state == 'pending'
            ? 'Follow request sent.'
            : 'You follow ${c.user.name} now.',
      );
    }
  });

  Future<void> answer(Connection c, bool accept) =>
      run('request:${c.user.userId}', () async {
        await actions.respondFollowRequest(c.user.userId, accept);
        requests?.removeWhere((i) => i.user.userId == c.user.userId);
        if (accept) await list.load();
        refreshCounts(c.user.userId);
        if (mounted) {
          showMessage(
            context,
            accept
                ? '${c.user.name} follows you now.'
                : 'Request from ${c.user.name} declined.',
          );
        }
      });

  Widget row(Connection c) {
    final id = c.user.userId;
    final off = busy.contains(id);
    final actions = <Widget>[
      if (own && !followers) ...[
        listAction(
          'Message',
          off ? null : () => messagePerson(context, ref, id, c.user.name),
          key: Key('message-$id'),
          icon: Icons.chat_bubble_outline_rounded,
        ),
        listAction(
          'Unfollow',
          off ? null : () => unfollow(c),
          key: Key('unfollow-$id'),
        ),
      ],
      if (own && followers) ...[
        if (c.following == 'none')
          listAction(
            'Follow back',
            off ? null : () => followBack(c),
            key: Key('follow-back-$id'),
            icon: Icons.person_add_alt_1_rounded,
            filled: true,
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Text(
              c.following == 'pending' ? 'Follow requested' : 'You follow them',
              key: Key('follows-$id'),
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        listAction(
          'Message',
          off ? null : () => messagePerson(context, ref, id, c.user.name),
          key: Key('message-$id'),
          icon: Icons.chat_bubble_outline_rounded,
        ),
        listAction(
          'Remove',
          off ? null : () => removeFollower(c),
          key: Key('remove-follower-$id'),
        ),
      ],
    ];
    return PersonRow(
      key: ValueKey('connection-$id'),
      person: c.user,
      subtitle: '@${c.user.username}',
      onOpen: () => openPerson(context, id),
      actions: actions,
    );
  }

  Widget requestsSection() {
    final pending = requests;
    if (pending == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: pending,
      builder: (context, _) {
        if (pending.items.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const Key('follow-requests'),
          padding: const EdgeInsets.only(bottom: 16),
          child: VibePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    'Follow requests',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 4),
                for (final r in pending.items)
                  PersonRow(
                    key: ValueKey('request-${r.user.userId}'),
                    person: r.user,
                    subtitle: '@${r.user.username} wants to follow you',
                    onOpen: () => openPerson(context, r.user.userId),
                    actions: [
                      FilledButton(
                        key: Key('approve-${r.user.userId}'),
                        onPressed: busy.contains('request:${r.user.userId}')
                            ? null
                            : () => answer(r, true),
                        child: const Text('Approve'),
                      ),
                      OutlinedButton(
                        key: Key('decline-${r.user.userId}'),
                        onPressed: busy.contains('request:${r.user.userId}')
                            ? null
                            : () => answer(r, false),
                        child: const Text('Decline'),
                      ),
                    ],
                  ),
                if (pending.cursor != null)
                  TextButton(
                    key: const Key('requests-more'),
                    onPressed: pending.more,
                    child: const Text('Show more requests'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = followers ? 'Followers' : 'Following';
    return ListPage<Connection>(
      title: title,
      backLabel: own ? 'Profile' : 'Back',
      backTo: own ? '/profile' : '/discover',
      list: list,
      header: [
        requestsSection(),
        if (own)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              followers
                  ? 'People who follow you, newest first.'
                  : 'People you follow, newest first.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
      ],
      row: row,
      calm: own
          ? null
          : (e) => e is ApiFailure && e.code == 'CONNECTIONS_PRIVATE'
                ? privateList(e)
                : null,
      empty: own
          ? EmptyCard(
              icon: followers
                  ? Icons.people_outline_rounded
                  : Icons.person_add_alt_1_rounded,
              title: followers
                  ? 'No followers yet'
                  : 'You’re not following anyone',
              description: followers
                  ? 'When someone follows you, they show up here.'
                  : 'Find people in Discover and follow the ones you like.',
              action: followers
                  ? null
                  : FilledButton(
                      onPressed: () => context.go('/discover'),
                      child: const Text('Find people'),
                    ),
            )
          : const EmptyCard(
              icon: Icons.people_outline_rounded,
              title: 'Nobody here yet',
              description: 'There’s no one to show right now.',
            ),
    );
  }
}
