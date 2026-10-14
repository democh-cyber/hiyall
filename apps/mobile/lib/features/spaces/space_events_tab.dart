import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../shared/segmented.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';
import 'space_join.dart';
import 'space_parts.dart';

/// The Events tab of a community as slivers: host shortcuts, plans grouped as
/// happening now / upcoming / earlier (built lazily) and a link to browse all.
class SpaceEventsSliver extends StatelessWidget {
  final SocialSpace space;

  /// Null until the tab has loaded.
  final List<SocialSpace>? plans;
  final Object? error;
  final bool loading;
  final VoidCallback onRetry;

  /// Opens [location], then reloads the plans when the person comes back.
  final Future<void> Function(String location) onOpenRoute;
  const SpaceEventsSliver({
    super.key,
    required this.space,
    required this.plans,
    required this.error,
    required this.loading,
    required this.onRetry,
    required this.onOpenRoute,
  });

  @override
  Widget build(BuildContext context) {
    final x = space;
    final list = plans ?? const <SocialSpace>[];
    final rows = _rows(list);
    return SliverMainAxisGroup(
      slivers: [
        if (x.host)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final kind in ['event', 'moment'])
                    ActionChip(
                      avatar: Icon(spaceKindStyle(kind).$1, size: 18),
                      label: Text('New ${spaceKindNames[kind]!.toLowerCase()}'),
                      onPressed: () => onOpenRoute(
                        '/spaces/new?kind=$kind&parent=${x.spaceId}',
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (plans == null || list.isEmpty)
          SliverToBoxAdapter(
            child: SpaceTabNotice(
              error: error,
              loading: loading,
              retry: onRetry,
              empty: x.host
                  ? 'No events or Moments yet. Plan the first one.'
                  : 'No events or Moments planned yet.',
            ),
          )
        else ...[
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => switch (rows[i]) {
              final String title => SpaceEyebrow(title),
              final SocialSpace p => SpacePlanRow(
                p,
                onOpen: () => onOpenRoute('/spaces/${p.spaceId}'),
              ),
              _ => const SizedBox(height: 8),
            },
          ),
          if (error != null)
            SliverToBoxAdapter(
              child: FailureCard(error: error!, retry: onRetry),
            ),
        ],
        SliverToBoxAdapter(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => context.push('/spaces?parent=${x.spaceId}'),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: const Text('Browse all'),
            ),
          ),
        ),
      ],
    );
  }

  /// A flat, lazily built list: a String is a group title, a [SocialSpace] a
  /// plan, and null the gap after a group.
  static List<Object?> _rows(List<SocialSpace> list) {
    final now = DateTime.now();
    final live = [
      for (final p in list)
        if (spaceTiming(p, now)?.startsWith('Live') == true) p,
    ];
    final upcoming = [
      for (final p in list)
        if (p.startsAt != null && p.startsAt!.isAfter(now)) p,
    ];
    final past = [
      for (final p in list)
        if (!live.contains(p) && !upcoming.contains(p)) p,
    ].reversed.toList();
    return [
      for (final (title, group) in [
        ('Happening now', live),
        ('Upcoming', upcoming),
        ('Earlier', past),
      ])
        if (group.isNotEmpty) ...[title, ...group, null],
    ];
  }
}

/// An event or Moment inside a community: when, what and who's in.
class SpacePlanRow extends ConsumerStatefulWidget {
  final SocialSpace space;
  final VoidCallback onOpen;
  const SpacePlanRow(this.space, {super.key, required this.onOpen});
  @override
  ConsumerState<SpacePlanRow> createState() => _SpacePlanRowState();
}

class _SpacePlanRowState extends ConsumerState<SpacePlanRow> {
  late SocialSpace s = widget.space;
  bool busy = false;
  @override
  void didUpdateWidget(SpacePlanRow old) {
    super.didUpdateWidget(old);
    if (old.space != widget.space) s = widget.space;
  }

  Future<void> _join() async {
    setState(() => busy = true);
    final next = await joinSpace(
      context,
      ref,
      s,
      rsvp: s.kind == 'event' ? 'interested' : 'going',
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (next != null) s = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final timing = spaceTiming(s);
    final live = timing?.startsWith('Live') == true;
    return Pressable(
      child: InkWell(
        borderRadius: BorderRadius.circular(VibeRadius.control),
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SpaceEmblem(s, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      live
                          ? timing!
                          : s.startsAt == null
                          ? (timing ?? '')
                          : whenLabel(s.startsAt!),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: live ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.title,
                      style: const TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${s.memberCount} ${s.kind == 'event' ? 'going or interested' : 'joined'}',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SpaceJoinButton(
                      s,
                      busy: busy,
                      onOpen: widget.onOpen,
                      onJoin: _join,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
