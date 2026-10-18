import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../core/user_error.dart';
import '../shared/person_link.dart';
import '../shared/profile_space/profile_details.dart' show recentVisitorsNote;
import '../shared/widgets.dart';
import 'people_lists/list_page.dart';
import 'people_lists/paged_list.dart';
import 'settings.dart' show timeAgo;

/// The line above "Places I've visited": who can see the list (nobody but you).
const placesVisitedNote =
    'Profiles you opened in the last 30 days, newest first. Only you can see this list. The people you visited can '
    'see that you did only if they chose to share their recent visitors.';

Session _session(WidgetRef ref) {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) throw const ApiFailure('Sign in to continue.');
  return session;
}

String _visited(VisitedPerson v) => 'Visited ${timeAgo(v.visitedAt)}';

/// Who opened a member's profile in the last 30 days, for a profile whose owner shares it. The server decides
/// everything: 403 VISITORS_PRIVATE when it is not shared, 404 when the profile is not available to you.
class RecentVisitorsScreen extends ConsumerStatefulWidget {
  final String userId;
  const RecentVisitorsScreen({super.key, required this.userId});
  @override
  ConsumerState<RecentVisitorsScreen> createState() => _RecentVisitorsState();
}

class _RecentVisitorsState extends ConsumerState<RecentVisitorsScreen> {
  late final PagedList<VisitedPerson> list;

  @override
  void initState() {
    super.initState();
    list = PagedList(
      (cursor) => ref
          .read(apiProvider)
          .recentVisitors(_session(ref), widget.userId, cursor),
    )..load();
  }

  @override
  void dispose() {
    list.dispose();
    super.dispose();
  }

  /// A refusal is not an error to retry: say it calmly.
  Widget? calm(Object error) {
    if (error is! ApiFailure) return null;
    if (error.code == 'VISITORS_PRIVATE') {
      return const EmptyCard(
        icon: Icons.visibility_off_outlined,
        title: 'Not shared',
        description: 'This member doesn’t share who visited their profile.',
      );
    }
    if (error.status == 404) {
      return const EmptyCard(
        icon: Icons.person_off_outlined,
        title: 'Not available',
        description: 'This profile isn’t available.',
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => ListPage<VisitedPerson>(
    title: 'Recent visitors',
    backLabel: 'Profile',
    backTo: '/person/${widget.userId}',
    list: list,
    calm: calm,
    header: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          recentVisitorsNote,
          key: const Key('recent-visitors-note'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
    ],
    row: (v) => PersonRow(
      key: ValueKey('visited-${v.user.userId}'),
      person: v.user,
      subtitle: '@${v.user.username} · ${_visited(v)}',
      onOpen: () => openPerson(context, v.user.userId),
    ),
    empty: const EmptyCard(
      icon: Icons.visibility_outlined,
      title: 'No recent visitors',
      description: 'Nobody opened this profile in the last 30 days.',
    ),
  );
}

/// The member's own visit history: the profiles they opened in the last 30 days (up to 200), newest first. Only
/// they can see it; "Clear history" deletes it.
class PlacesVisitedScreen extends ConsumerStatefulWidget {
  const PlacesVisitedScreen({super.key});
  @override
  ConsumerState<PlacesVisitedScreen> createState() => _PlacesVisitedState();
}

class _PlacesVisitedState extends ConsumerState<PlacesVisitedScreen> {
  late final PagedList<VisitedPerson> list;
  bool clearing = false;

  @override
  void initState() {
    super.initState();
    list = PagedList(
      (cursor) => ref.read(apiProvider).placesVisited(_session(ref), cursor),
    )..load();
  }

  @override
  void dispose() {
    list.dispose();
    super.dispose();
  }

  Future<void> clear() async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Clear your history?'),
            content: const Text(
              'This removes the list of profiles you opened. It doesn’t change anyone’s visitor count.',
            ),
            actions: [
              TextButton(
                key: const Key('confirm-cancel'),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirm-ok'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear history'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    setState(() => clearing = true);
    try {
      await ref.read(apiProvider).clearPlacesVisited(_session(ref));
      await list.load();
      if (mounted) showMessage(context, 'History cleared.');
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: list,
    builder: (context, _) => ListPage<VisitedPerson>(
      title: 'Places I’ve visited',
      backLabel: 'Settings',
      backTo: '/profile/settings',
      list: list,
      trailing: list.items.isEmpty
          ? null
          : TextButton(
              key: const Key('places-clear'),
              onPressed: clearing ? null : clear,
              child: const Text('Clear'),
            ),
      header: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            placesVisitedNote,
            key: const Key('places-note'),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      ],
      row: (v) => PersonRow(
        key: ValueKey('place-${v.user.userId}'),
        person: v.user,
        subtitle: '@${v.user.username} · ${_visited(v)}',
        onOpen: () => openPerson(context, v.user.userId),
      ),
      empty: const EmptyCard(
        icon: Icons.history_rounded,
        title: 'Nothing here yet',
        description: 'Profiles you open show up here for 30 days.',
      ),
    ),
  );
}
