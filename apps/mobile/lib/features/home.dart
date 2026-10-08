import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/activity_state.dart';
import '../core/api.dart';
import '../core/feed_state.dart';
import '../core/discovery.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/profile_space.dart';
import '../shared/widgets.dart';
import 'live_sync.dart';
import 'pulse.dart';

/// A short, unfiltered first page of Discover: the same opted-in adults the
/// Discover tab would show, so Home never widens who can be found. Kept for the
/// session; pull-to-refresh or a new sign-in reloads it.
final homeSuggestionsProvider = FutureProvider.autoDispose<List<Profile>>((
  ref,
) async {
  final session = requireSession(ref);
  // Suggestions change slowly; don't re-query on every tab switch.
  ref.keepAlive();
  final data = await ref
      .watch(apiProvider)
      .searchPeople(session, PeopleFilters().toJson());
  return [
    for (final item in data['items'] as List)
      Profile.fromJson(Map<String, dynamic>.from(item as Map)),
  ].where((p) => p.userId != session.userId).take(10).toList();
}, retry: apiReadRetry);

/// What an unfinished profile is still missing, in the order worth fixing.
List<String> missingProfileParts(Profile p) => [
  if (p.bio.trim().isEmpty) 'Bio',
  if (p.headline.trim().isEmpty) 'Headline',
  if (p.currentVibe.trim().isEmpty) 'Current vibe',
  if (p.interests.isEmpty) 'Interests',
  if (p.languages.isEmpty) 'Languages',
  if (p.pronouns.trim().isEmpty) 'Pronouns',
];

const _profileParts = 6;
const _cardTextScale = 1.6;

String greetingFor(DateTime now) => switch (now.hour) {
  < 5 => 'STILL UP',
  < 12 => 'GOOD MORNING',
  < 17 => 'GOOD AFTERNOON',
  < 22 => 'GOOD EVENING',
  _ => 'WINDING DOWN',
};

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String mode = 'following';

  Future<void> refresh() async {
    ref.invalidate(homeSuggestionsProvider);
    ref.invalidate(profileProvider);
    ref.invalidate(storyTrayProvider);
    try {
      await ref.read(feedProvider(mode).notifier).refresh();
      await ref.read(activityProvider.notifier).refresh();
      await ref.read(chatUnreadProvider.notifier).refresh();
    } catch (_) {}
  }

  bool onScroll(ScrollNotification n) {
    // Fetch the next page while a screen or two of posts is still left.
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 1200) {
      ref.read(feedProvider(mode).notifier).loadMore().catchError((_) {});
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).asData?.value;
    final activity = ref.watch(activityProvider).asData?.value;
    final unreadChats = ref.watch(chatUnreadProvider);
    final feed = ref.watch(feedProvider(mode));
    final posts = feed.asData?.value.items ?? const <Post>[];
    final requests = [
      for (final i in activity?.items ?? const <Map<String, dynamic>>[])
        if (isPendingRequest(i)) i,
    ];
    final missing = profile == null
        ? const <String>[]
        : missingProfileParts(profile);
    // Suggestions sit after the third post, or under a quiet feed.
    final suggestAt = posts.isEmpty ? -1 : math.min(3, posts.length);

    return ReadingWidth(
      child: RefreshIndicator(
        onRefresh: refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: onScroll,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                sliver: SliverList.list(
                  children: [
                    _Greeting(name: profile?.displayName),
                    const SizedBox(height: 16),
                    const StoryTray(),
                    const SizedBox(height: 14),
                    _PulseStrip(
                      unreadChats: unreadChats,
                      requests: requests.length,
                      newActivity: activity?.unread ?? 0,
                    ),
                    if (requests.isNotEmpty) ...[
                      _Heading(
                        'Waiting on you',
                        action: requests.length > 2 ? 'See all' : null,
                        onAction: () => context.go('/notifications'),
                      ),
                      for (final r in requests.take(2)) _RequestRow(item: r),
                    ],
                    if (profile != null && missing.isNotEmpty)
                      _ProfileProgress(missing: missing),
                    Padding(
                      padding: const EdgeInsets.only(top: 26, bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Pulse',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 10),
                          SegmentedButton<String>(
                            key: const Key('feed-mode'),
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(
                                value: 'following',
                                label: Text('Your people'),
                              ),
                              ButtonSegment(
                                value: 'everyone',
                                label: Text('Everyone'),
                              ),
                            ],
                            selected: {mode},
                            onSelectionChanged: (s) =>
                                setState(() => mode = s.single),
                          ),
                        ],
                      ),
                    ),
                    if (feed.hasError && posts.isEmpty)
                      FailureCard(
                        error: feed.error!,
                        retry: () => ref.invalidate(feedProvider(mode)),
                      )
                    else if (feed.isLoading && posts.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (posts.isEmpty) ...[
                      EmptyCard(
                        key: const Key('feed-empty'),
                        icon: Icons.auto_awesome_rounded,
                        title: mode == 'following'
                            ? 'Your Pulse is quiet'
                            : 'Nothing public yet',
                        description: mode == 'following'
                            ? 'Follow a few people or share something of your own.'
                            : 'Public posts from everyone show up here.',
                        action: FilledButton.icon(
                          onPressed: () => context.push('/compose'),
                          icon: const Icon(Icons.edit_note_rounded),
                          label: const Text('Share a post'),
                        ),
                      ),
                      const _Suggestions(),
                    ],
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList.builder(
                  itemCount: posts.length,
                  itemBuilder: (context, i) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PostCard(post: posts[i], mode: mode),
                      if (i + 1 == suggestAt)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 14),
                          child: _Suggestions(),
                        ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 120),
                  child: feed.asData?.value.loadingMore ?? false
                      ? const Center(child: CircularProgressIndicator())
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  final String? name;
  const _Greeting({required this.name});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VibeTag(
          greetingFor(DateTime.now()),
          color: VibeColors.lime,
          icon: Icons.auto_awesome,
        ),
        const SizedBox(height: 12),
        Text(
          name == null ? 'Your orbit' : 'Hey, $name.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Here’s what’s happening with your people.',
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
        ),
      ],
    );
  }
}

class _PulseStrip extends StatelessWidget {
  final int unreadChats, requests, newActivity;
  const _PulseStrip({
    required this.unreadChats,
    required this.requests,
    required this.newActivity,
  });
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _PulseTile(
          key: const Key('home-pulse-chats'),
          count: unreadChats,
          label: unreadChats == 1 ? 'message' : 'messages',
          icon: Icons.chat_bubble_outline_rounded,
          color: VibeColors.lilac,
          onTap: () => context.go('/chats'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _PulseTile(
          key: const Key('home-pulse-requests'),
          count: requests,
          label: requests == 1 ? 'request' : 'requests',
          icon: Icons.person_add_alt_rounded,
          color: VibeColors.pink,
          onTap: () => context.go('/notifications'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _PulseTile(
          key: const Key('home-pulse-activity'),
          count: newActivity,
          label: 'activity',
          icon: Icons.bolt_rounded,
          color: VibeColors.mint,
          onTap: () => context.go('/notifications'),
        ),
      ),
    ],
  );
}

class _PulseTile extends StatelessWidget {
  final int count;
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _PulseTile({
    super.key,
    required this.count,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = count > 0;
    return Semantics(
      button: true,
      label: '$count $label',
      excludeSemantics: true,
      child: Material(
        color: active ? color : scheme.surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: active ? color : scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: active ? VibeColors.ink : scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 14),
                Text(
                  count > 99 ? '99+' : '$count',
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: 28,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: active ? VibeColors.ink : scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? VibeColors.ink.withValues(alpha: .75)
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const _Heading(this.title, {this.action, this.onAction});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    ),
  );
}

class _Initial extends StatelessWidget {
  final String name;
  final Color color;
  static const double radius = 22;
  const _Initial(this.name, {this.color = VibeColors.lilac});
  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundColor: color,
    foregroundColor: VibeColors.ink,
    child: Text(
      name.characters.firstOrNull?.toUpperCase() ?? '?',
      style: TextStyle(fontWeight: FontWeight.w800, fontSize: radius * .8),
    ),
  );
}

class _RequestRow extends ConsumerWidget {
  final Map<String, dynamic> item;
  const _RequestRow({required this.item});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actor = (item['actors'] as List).first as Map;
    final name = (actor['displayName'] ?? actor['username'] ?? '') as String;
    final id = item['notificationId'];
    Future<void> respond(bool accept) async {
      try {
        await ref.read(activityProvider.notifier).respond(item, accept);
      } catch (e) {
        if (context.mounted) showMessage(context, e.toString());
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: VibePanel(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => context.go('/discover/person/${actor['userId']}'),
              child: _Initial(name, color: VibeColors.pink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item['text'] as String? ?? name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              key: Key('home-decline-$id'),
              tooltip: 'Decline',
              onPressed: () => respond(false),
              icon: const Icon(Icons.close_rounded),
            ),
            IconButton.filled(
              key: Key('home-accept-$id'),
              tooltip: 'Accept',
              onPressed: () => respond(true),
              icon: const Icon(Icons.check_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _Suggestions extends ConsumerWidget {
  const _Suggestions();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(homeSuggestionsProvider).asData?.value;
    if (people == null || people.isEmpty) return const SizedBox.shrink();
    final own = ref.watch(profileProvider).asData?.value;
    final mine = {...?own?.interests};
    final scaler = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: _cardTextScale);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(
          'People you might vibe with',
          action: 'Discover',
          onAction: () => context.go('/discover'),
        ),
        SizedBox(
          // Fixed chrome plus text that grows with the reader's text size.
          height: 112 + scaler.scale(84),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: people.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final p = people[i];
              final shared = p.interests.where(mine.contains).length;
              return MediaQuery.withClampedTextScaling(
                maxScaleFactor: _cardTextScale,
                child: _PersonCard(person: p, shared: shared),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PersonCard extends StatelessWidget {
  final Profile person;
  final int shared;
  const _PersonCard({required this.person, required this.shared});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = profileAccent(person);
    final line = [person.currentVibe, person.headline, person.profession]
        .firstWhere(
          (s) => s.trim().isNotEmpty,
          orElse: () => '@${person.username}',
        );
    return SizedBox(
      width: 150,
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('home-person-${person.userId}'),
          onTap: () => context.go('/discover/person/${person.userId}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 64,
                color: accent.withValues(alpha: .55),
                alignment: Alignment.bottomLeft,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: Transform.translate(
                  offset: const Offset(0, 22),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 3),
                    ),
                    child: _Initial(person.displayName, color: accent),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 28, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        person.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Flexible(
                        child: Text(
                          line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (shared > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          shared == 1
                              ? '1 shared interest'
                              : '$shared shared interests',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: VibeColors.success,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileProgress extends StatelessWidget {
  final List<String> missing;
  const _ProfileProgress({required this.missing});
  @override
  Widget build(BuildContext context) {
    final done = _profileParts - missing.length;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: VibePanel(
        color: VibeColors.lime,
        padding: const EdgeInsets.all(20),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: VibeColors.ink),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Make it feel like you',
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '$done/$_profileParts',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: done / _profileParts,
                  minHeight: 8,
                  color: VibeColors.ink,
                  backgroundColor: VibeColors.ink.withValues(alpha: .12),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Still missing: ${missing.take(3).join(', ')}'
                '${missing.length > 3 ? ' and more' : ''}.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: VibeColors.ink,
                  foregroundColor: VibeColors.lime,
                ),
                onPressed: () => context.go('/profile/edit'),
                icon: const Icon(Icons.arrow_outward, size: 16),
                label: const Text('Make it yours'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
