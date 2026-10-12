import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/activity_state.dart';
import '../core/api.dart';
import '../core/feed_state.dart';
import '../core/state.dart';
import '../shared/person_avatar.dart';
import '../shared/person_link.dart';
import '../shared/profile_stats.dart';
import '../shared/story_canvas.dart';
import '../shared/widgets.dart';
import 'chat.dart';
import 'pulse.dart';
import 'settings.dart' show timeAgo;

/// A list read a page at a time from the server's signed cursor. The server
/// decides who may read it and what it leaves out; this only holds the pages.
class PagedList<T> extends ChangeNotifier {
  final Future<ApiPage<T>> Function(String? cursor) fetch;
  PagedList(this.fetch);

  List<T> items = const [];
  String? cursor;
  bool loaded = false, loading = false, loadingMore = false;

  /// Why the first page could not be read; null once it was.
  Object? error;
  int _epoch = 0;
  bool _disposed = false;

  void _tell() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Reads the first page again. The old rows stay on screen until it lands.
  Future<void> load() async {
    final epoch = ++_epoch;
    loading = true;
    error = null;
    _tell();
    try {
      final page = await fetch(null);
      if (epoch != _epoch) return;
      items = page.items;
      cursor = page.nextCursor;
      loaded = true;
    } catch (e) {
      if (epoch != _epoch) return;
      error = e;
    } finally {
      if (epoch == _epoch) {
        loading = false;
        loadingMore = false;
        _tell();
      }
    }
  }

  /// Reads the next page; returns what went wrong, if anything.
  Future<Object?> more() async {
    final next = cursor;
    if (next == null || loadingMore || loading) return null;
    final epoch = _epoch;
    loadingMore = true;
    _tell();
    try {
      final page = await fetch(next);
      if (epoch != _epoch) return null;
      items = [...items, ...page.items];
      cursor = page.nextCursor;
      return null;
    } catch (e) {
      return e;
    } finally {
      if (epoch == _epoch) {
        loadingMore = false;
        _tell();
      }
    }
  }

  void removeWhere(bool Function(T item) test) {
    items = [
      for (final i in items)
        if (!test(i)) i,
    ];
    _tell();
  }

  void replaceWhere(bool Function(T item) test, T Function(T item) change) {
    items = [for (final i in items) test(i) ? change(i) : i];
    _tell();
  }
}

/// Starts a chat with [userId], as the Message button on a profile does.
Future<void> messagePerson(
  BuildContext context,
  WidgetRef ref,
  String userId,
  String name,
) async {
  if (!chatSupported) {
    showMessage(context, 'Chats are available in the Android and iOS apps.');
    return;
  }
  try {
    final engine = await ref.read(chatEngineProvider.future);
    final id = await engine!.open(userId);
    if (context.mounted) {
      context.go(
        '/chats/$id?peer=${Uri.encodeQueryComponent(userId)}&name=${Uri.encodeQueryComponent(name)}',
      );
    }
  } catch (e) {
    if (context.mounted) showMessage(context, chatError(e));
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const Key('confirm-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// The frame every list screen shares: a back button, a title, optional lines
/// above the rows, then loading, error, empty and paged states.
class _ListPage<T> extends StatelessWidget {
  final String title, backLabel, backTo;
  final PagedList<T> list;
  final List<Widget> header;
  final Widget Function(T item) row;
  final Widget empty;

  /// Shown instead of the retry card for failures that are not worth retrying.
  final Widget? Function(Object error)? calm;
  final Widget? trailing;
  const _ListPage({
    required this.title,
    required this.backLabel,
    required this.backTo,
    required this.list,
    required this.row,
    required this.empty,
    this.header = const [],
    this.calm,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => ReadingWidth(
    child: ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final error = list.error;
        final Widget body;
        if (!list.loaded && list.loading) {
          body = const VibeLoading();
        } else if (error != null && list.items.isEmpty) {
          body =
              calm?.call(error) ?? FailureCard(error: error, retry: list.load);
        } else if (list.loaded && list.items.isEmpty) {
          body = empty;
        } else {
          body = Column(
            children: [
              for (final item in list.items) row(item),
              if (list.cursor != null || list.loadingMore)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: list.loadingMore
                      ? const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : OutlinedButton(
                          key: const Key('list-more'),
                          onPressed: () async {
                            final failure = await list.more();
                            if (failure != null && context.mounted) {
                              showMessage(context, failure.toString());
                            }
                          },
                          child: const Text('Show more'),
                        ),
                ),
            ],
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 240 &&
                list.cursor != null &&
                !list.loadingMore &&
                !list.loading) {
              list.more();
            }
            return false;
          },
          child: RefreshIndicator(
            onRefresh: list.load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('list-back'),
                    onPressed: () => goBack(context, backTo),
                    icon: const Icon(Icons.arrow_back),
                    label: Text(backLabel),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: 8),
                ...header,
                body,
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// One person in a list: tap the head to open their profile, with any actions
/// on a line below so they never crowd the name at large text sizes.
class _PersonRow extends StatelessWidget {
  final Person person;
  final String subtitle;
  final VoidCallback onOpen;
  final List<Widget> actions;
  const _PersonRow({
    super.key,
    required this.person,
    required this.subtitle,
    required this.onOpen,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onOpen,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  PersonAvatar(
                    name: person.name,
                    avatarUrl: person.avatarUrl,
                    userId: person.userId,
                    radius: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          person.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 56, top: 2),
              child: Wrap(spacing: 8, runSpacing: 4, children: actions),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}

Widget _action(
  String label,
  VoidCallback? onPressed, {
  required Key key,
  IconData? icon,
  bool filled = false,
}) {
  final style = (filled ? FilledButton.styleFrom : OutlinedButton.styleFrom)(
    visualDensity: VisualDensity.compact,
    minimumSize: const Size(48, 40),
  );
  final text = Text(label);
  return filled
      ? FilledButton.tonalIcon(
          key: key,
          onPressed: onPressed,
          style: style,
          icon: icon == null ? null : Icon(icon, size: 16),
          label: text,
        )
      : OutlinedButton.icon(
          key: key,
          onPressed: onPressed,
          style: style,
          icon: icon == null ? null : Icon(icon, size: 16),
          label: text,
        );
}

Widget _privateList(Object error) =>
    error is ApiFailure && error.code == 'CONNECTIONS_PRIVATE'
    ? const EmptyCard(
        icon: Icons.lock_outline_rounded,
        title: 'Not shared',
        description: 'This member keeps their lists to themselves.',
      )
    : FailureCard(error: error, retry: () {});

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
  Session get session => ref.read(sessionProvider).asData!.value!;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiProvider);
    list = PagedList(
      (cursor) => api.connections(
        session,
        widget.kind,
        userId: widget.userId,
        cursor: cursor,
      ),
    )..load();
    if (own && followers) {
      requests = PagedList((cursor) => api.followRequests(session, cursor))
        ..load();
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
      if (mounted) showMessage(context, e.toString());
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
    if (!await _confirm(
      context,
      title: 'Unfollow ${c.user.name}?',
      body: 'You can follow again any time.',
      action: 'Unfollow',
    )) {
      return;
    }
    await run(c.user.userId, () async {
      await ref.read(apiProvider).unfollow(session, c.user.userId);
      list.removeWhere((i) => i.user.userId == c.user.userId);
      refreshCounts(c.user.userId);
      if (mounted) showMessage(context, 'Unfollowed ${c.user.name}.');
    });
  }

  Future<void> removeFollower(Connection c) async {
    if (!await _confirm(
      context,
      title: 'Remove ${c.user.name} as a follower?',
      body: 'They’ll stop following you and won’t be told. They can follow you again unless you block them.',
      action: 'Remove',
    )) {
      return;
    }
    await run(c.user.userId, () async {
      await ref.read(apiProvider).removeFollower(session, c.user.userId);
      list.removeWhere((i) => i.user.userId == c.user.userId);
      refreshCounts(c.user.userId);
      if (mounted) showMessage(context, 'Removed ${c.user.name}.');
    });
  }

  Future<void> followBack(Connection c) => run(c.user.userId, () async {
    final state = await ref.read(apiProvider).follow(session, c.user.userId);
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
        await ref
            .read(apiProvider)
            .respondFollowRequest(session, c.user.userId, accept);
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
        _action(
          'Message',
          off ? null : () => messagePerson(context, ref, id, c.user.name),
          key: Key('message-$id'),
          icon: Icons.chat_bubble_outline_rounded,
        ),
        _action(
          'Unfollow',
          off ? null : () => unfollow(c),
          key: Key('unfollow-$id'),
        ),
      ],
      if (own && followers) ...[
        if (c.following == 'none')
          _action(
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
        _action(
          'Message',
          off ? null : () => messagePerson(context, ref, id, c.user.name),
          key: Key('message-$id'),
          icon: Icons.chat_bubble_outline_rounded,
        ),
        _action(
          'Remove',
          off ? null : () => removeFollower(c),
          key: Key('remove-follower-$id'),
        ),
      ],
    ];
    return _PersonRow(
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
                  _PersonRow(
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
    return _ListPage<Connection>(
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
                ? _privateList(e)
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
  Session get session => ref.read(sessionProvider).asData!.value!;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiProvider);
    list = PagedList((cursor) => api.visitors(session, cursor))..load();
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
      final state = await ref.read(apiProvider).follow(session, id);
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
      if (mounted) showMessage(context, e.toString());
    } finally {
      busy.remove(id);
    }
  }

  Future<void> block(Visitor v) async {
    if (!await _confirm(
      context,
      title: 'Block ${v.user.name}?',
      body: 'They won’t be able to find your profile, follow you or message you. Your follows and friendship end, and your chat closes. They won’t be told.',
      action: 'Block',
    )) {
      return;
    }
    final id = v.user.userId;
    try {
      await ref.read(apiProvider).block(session, id, true);
      list.removeWhere((i) => i.user.userId == id);
      ref.invalidate(profileProvider);
      ref.invalidate(otherProfileProvider(id));
      if (mounted) showMessage(context, 'Account blocked.');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  Widget row(Visitor v) {
    final id = v.user.userId;
    return Stack(
      key: ValueKey('visitor-$id'),
      alignment: AlignmentDirectional.topEnd,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 48),
          child: _PersonRow(
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
  Widget build(BuildContext context) => _ListPage<Visitor>(
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

/// Your active stories (they last up to 24 hours), newest first: who saw each, when
/// it goes, and a way to delete it or add another.
class MyStoriesScreen extends ConsumerStatefulWidget {
  const MyStoriesScreen({super.key});
  @override
  ConsumerState<MyStoriesScreen> createState() => _MyStoriesState();
}

/// How long a story has left: "23h left", "40m left".
String storyTimeLeft(DateTime expiresAt, [DateTime? now]) {
  final d = expiresAt.difference(now ?? DateTime.now());
  if (d.inMinutes < 1) return 'Ends in under a minute';
  if (d.inHours < 1) return '${d.inMinutes}m left';
  return '${d.inHours}h left';
}

class _MyStoriesState extends ConsumerState<MyStoriesScreen> {
  late final PagedList<Story> list;
  Session get session => ref.read(sessionProvider).asData!.value!;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiProvider);
    list = PagedList((cursor) => api.myStories(session, cursor))..load();
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
    if (!await _confirm(
      context,
      title: 'Delete this story?',
      body: 'It disappears for everyone right away and can’t be brought back.',
      action: 'Delete',
    )) {
      return;
    }
    try {
      await ref.read(apiProvider).deleteStory(session, story.storyId);
      list.removeWhere((i) => i.storyId == story.storyId);
      ref.invalidate(profileProvider);
      ref.invalidate(storyTrayProvider);
      if (mounted) showMessage(context, 'Story deleted.');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    }
  }

  Future<void> viewers(Story story) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => _StoryViewersSheet(
      story: story,
      onOpen: (id) {
        Navigator.pop(sheet);
        openPerson(context, id);
      },
    ),
  );

  Widget row(Story s) {
    final scheme = Theme.of(context).colorScheme;
    final seen = s.viewCount ?? 0;
    // The same canvas as the viewer, in miniature.
    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 64,
        height: 88,
        child: StoryCanvas(
          decorative: true,
          background: s.background,
          textStyle: s.textStyle,
          body: s.body,
          photo: s.media != null && s.media!.thumbUrl.isNotEmpty
              ? Image.network(
                  s.media!.thumbUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      ColoredBox(color: scheme.surfaceContainerHighest),
                )
              : null,
        ),
      ),
    );
    return Padding(
      key: ValueKey('story-${s.storyId}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              key: Key('story-open-${s.storyId}'),
              borderRadius: BorderRadius.circular(14),
              onTap: () => viewers(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    preview,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.body.isEmpty ? 'Photo story' : s.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${storyTimeLeft(s.expiresAt)} · posted ${timeAgo(s.createdAt)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                audienceIcon(s.audience),
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  audienceLabels[s.audience] ?? s.audience,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.visibility_outlined,
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                seen == 1 ? 'Seen by 1' : 'Seen by $seen',
                                key: Key('story-views-${s.storyId}'),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: Key('story-delete-${s.storyId}'),
            tooltip: 'Delete story',
            onPressed: () => delete(s),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _ListPage<Story>(
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

/// Who watched one of your stories, most recent first.
class _StoryViewersSheet extends ConsumerStatefulWidget {
  final Story story;
  final void Function(String userId) onOpen;
  const _StoryViewersSheet({required this.story, required this.onOpen});
  @override
  ConsumerState<_StoryViewersSheet> createState() => _StoryViewersState();
}

class _StoryViewersState extends ConsumerState<_StoryViewersSheet> {
  late final PagedList<Connection> list;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiProvider);
    final session = ref.read(sessionProvider).asData!.value!;
    list = PagedList(
      (cursor) async => _viewers(
        await api.storyViewers(session, widget.story.storyId, cursor),
      ),
    )..load();
  }

  static ApiPage<Connection> _viewers(ApiPage<Map<String, dynamic>> page) =>
      ApiPage([
        for (final v in page.items) Connection.fromJson(v),
      ], page.nextCursor);

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
          body = ListView(
            children: [
              for (final v in list.items)
                ListTile(
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
                ),
              if (list.cursor != null)
                TextButton(
                  key: const Key('viewers-more'),
                  onPressed: list.more,
                  child: const Text('Show more'),
                ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Seen by ${widget.story.viewCount ?? 0}',
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

/// Where each tappable stat leads on your own profile.
ProfileStatActions ownStatActions(BuildContext context) => {
  ProfileStat.following: () => context.push('/profile/following'),
  ProfileStat.followers: () => context.push('/profile/followers'),
  ProfileStat.visitors: () => context.push('/profile/visitors'),
  ProfileStat.stories: () => context.push('/profile/stories'),
};

/// Where each tappable stat leads on someone else's profile: their lists when
/// the server says you may open them, their stories when there are some you may
/// watch, and never the visitors (those are for them alone).
ProfileStatActions otherStatActions(
  BuildContext context,
  WidgetRef ref,
  Profile profile,
) {
  final stats = profile.socialStats;
  return {
    if (profile.canSeeConnections) ...{
      ProfileStat.following: () =>
          context.push('/person/${profile.userId}/following'),
      ProfileStat.followers: () =>
          context.push('/person/${profile.userId}/followers'),
    },
    if (stats != null && stats.stories > 0)
      ProfileStat.stories: () => watchStories(context, ref, profile),
  };
}

/// Opens someone's stories you may watch in the story viewer.
Future<void> watchStories(
  BuildContext context,
  WidgetRef ref,
  Profile profile,
) async {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return;
  try {
    final page = await ref
        .read(apiProvider)
        .userStories(session, profile.userId);
    if (!context.mounted) return;
    if (page.items.isEmpty) {
      showMessage(context, 'No stories to watch right now.');
      return;
    }
    openStories(context, [
      StoryGroup(
        Person(
          profile.userId,
          profile.username,
          profile.displayName,
          avatarUrl: profile.avatarUrl,
        ),
        // Played oldest first, as in the tray.
        page.items.reversed.toList(),
      ),
    ], 0);
  } catch (e) {
    if (context.mounted) showMessage(context, e.toString());
  }
}
