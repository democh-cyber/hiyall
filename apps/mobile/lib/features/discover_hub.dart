import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../shared/segmented.dart' show EntranceFade;
import 'discover_header.dart';
import 'discovery.dart';
import 'spaces.dart';

/// The first page of spaces of one kind, for the Circles and Moments tabs.
final spacePreviewProvider = FutureProvider.autoDispose
    .family<List<SocialSpace>, (String, bool)>((ref, key) async {
      final session = ref.watch(sessionProvider).asData?.value;
      if (session == null) return const [];
      final page = await ref
          .watch(apiProvider)
          .spaces(session, key.$1, mine: key.$2);
      return page.items;
    });

/// Discover opens directly on the filterable people list. Other discovery
/// sections remain available without adding another set of tabs above it.
class DiscoverHub extends ConsumerStatefulWidget {
  const DiscoverHub({super.key});
  @override
  ConsumerState<DiscoverHub> createState() => _DiscoverHubState();
}

class _DiscoverHubState extends ConsumerState<DiscoverHub> {
  String section = 'people';

  Future<void> refreshSpaces() async {
    ref.invalidate(spacePreviewProvider);
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          children: [
            DiscoveryHeader(
              title: switch (section) {
                'circles' => 'Circles',
                'moments' => 'Moments',
                _ => 'Find your people.',
              },
              trailing: PopupMenuButton<String>(
                tooltip: 'Explore Discover',
                initialValue: section,
                icon: const Icon(Icons.explore_outlined, size: 22),
                onSelected: (value) => setState(() => section = value),
                itemBuilder: (_) => [
                  for (final (value, label) in const [
                    ('people', 'People'),
                    ('circles', 'Circles'),
                    ('moments', 'Moments'),
                  ])
                    CheckedPopupMenuItem(
                      key: Key('discover-tab-$value'),
                      value: value,
                      checked: section == value,
                      child: Text(label),
                    ),
                ],
              ),
            ),
            Expanded(
              child: section == 'people'
                  ? const PeopleDiscovery()
                  : RefreshIndicator(
                      onRefresh: refreshSpaces,
                      child: SingleChildScrollView(
                        key: ValueKey(section),
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(top: 16, bottom: 40),
                        child: section == 'circles'
                            ? const _CirclesTab()
                            : const _MomentsTab(),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

// --------------------------------------------------------------- Circles

/// Title, line and a "see all" link opening a content section.
class _SectionHead extends StatelessWidget {
  final String title;
  final String? more;
  final VoidCallback? onMore;
  const _SectionHead(this.title, {this.more, this.onMore});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
        if (more != null) TextButton(onPressed: onMore, child: Text(more!)),
      ],
    ),
  );
}

/// The intro row for Circles and Moments: one line of copy and a way in.
class _Intro extends StatelessWidget {
  final String title, body, action;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;
  const _Intro({
    required this.title,
    required this.body,
    required this.action,
    required this.icon,
    required this.tint,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: VibeColors.ink),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: onTap,
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: Text(action),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _spaceList(
  BuildContext context,
  WidgetRef ref,
  AsyncValue<List<SocialSpace>> value, {
  required List<SocialSpace> Function(List<SocialSpace>) pick,
  required String empty,
  VoidCallback? retry,
}) => value.when(
  skipLoadingOnRefresh: true,
  loading: () => const VibeLoading(),
  error: (e, _) => FailureCard(
    error: e,
    retry: retry ?? () => ref.invalidate(spacePreviewProvider),
  ),
  data: (all) {
    final items = pick(all);
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          empty,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final (i, s) in items.indexed)
          EntranceFade(
            key: ValueKey(s.spaceId),
            delayMs: math.min(i, 4) * 40,
            child: SpaceCard(
              s,
              onOpen: () async {
                await context.push('/spaces/${s.spaceId}');
                ref.invalidate(spacePreviewProvider);
              },
              onChanged: (_) => ref.invalidate(spacePreviewProvider),
            ),
          ),
      ],
    );
  },
);

class _CirclesTab extends ConsumerWidget {
  const _CirclesTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final joined = ref.watch(spacePreviewProvider(('community', true)));
    final all = ref.watch(spacePreviewProvider(('community', false)));
    final hasJoined = joined.asData?.value.isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Intro(
            title: 'Find your circle',
            body: 'Small circles. Real conversations. Communities around things you actually care about.',
            action: 'Explore circles',
            icon: Icons.groups_rounded,
            tint: VibeColors.lilac,
            onTap: () => context.push('/spaces'),
          ),
          if (hasJoined) ...[
            const _SectionHead('Your circles'),
            _spaceList(
              context,
              ref,
              joined,
              pick: (x) => x.take(3).toList(),
              empty: '',
            ),
          ],
          _SectionHead(
            hasJoined ? 'More to explore' : 'Circles to explore',
            more: 'See all',
            onMore: () => context.push('/spaces'),
          ),
          _spaceList(
            context,
            ref,
            all,
            pick: (x) => [
              for (final s in x)
                if (!s.joined) s,
            ].take(5).toList(),
            empty: hasJoined
                ? 'You’re in every circle we can show right now.'
                : 'No circles yet. Start the first one from Explore circles.',
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- Moments

class _MomentsTab extends ConsumerWidget {
  const _MomentsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moments = ref.watch(spacePreviewProvider(('moment', false)));
    final events = ref.watch(spacePreviewProvider(('event', false)));
    final combined = moments.hasError
        ? moments
        : events.hasError
        ? events
        : moments.isLoading || events.isLoading
        ? const AsyncLoading<List<SocialSpace>>()
        : AsyncData([...moments.value!, ...events.value!]);
    final now = DateTime.now();
    bool live(SocialSpace s) => spaceTiming(s, now)?.startsWith('Live') == true;
    bool soon(SocialSpace s) =>
        s.status == 'open' && s.startsAt != null && s.startsAt!.isAfter(now);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Intro(
            title: 'Catch a Moment',
            body: 'Short, timed get-togethers and events. Join while they’re live.',
            action: 'Browse all',
            icon: Icons.bolt_rounded,
            tint: VibeColors.lime,
            onTap: () => context.push('/spaces?kind=moment'),
          ),
          const _SectionHead('Happening now'),
          _spaceList(
            context,
            ref,
            combined,
            pick: (x) => x.where(live).take(5).toList(),
            empty: 'Nothing live right now.',
          ),
          _SectionHead(
            'Coming up',
            more: 'Events',
            onMore: () => context.push('/spaces?kind=event'),
          ),
          _spaceList(
            context,
            ref,
            combined,
            pick: (x) =>
                (x.where(soon).toList()
                      ..sort((a, b) => a.startsAt!.compareTo(b.startsAt!)))
                    .take(6)
                    .toList(),
            empty: 'No upcoming plans yet.',
          ),
        ],
      ),
    );
  }
}
