import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../shared/person_link.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';
import 'space_parts.dart';

/// The Members tab as slivers: heading with a Manage shortcut for moderators,
/// member rows built lazily, "Show more members" and any failure.
class SpaceMembersSliver extends StatelessWidget {
  final SocialSpace space;

  /// Null until the tab has loaded.
  final List<SpaceMember>? members;
  final bool hasMore, loading;
  final Object? error;
  final VoidCallback onRetry, onMore, onManage;
  const SpaceMembersSliver({
    super.key,
    required this.space,
    required this.members,
    required this.hasMore,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onMore,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final x = space;
    final list = members ?? const <SpaceMember>[];
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(child: SpaceEyebrow('Members · ${x.memberCount}')),
              if (x.moderate)
                TextButton(onPressed: onManage, child: const Text('Manage')),
            ],
          ),
        ),
        if (members == null || list.isEmpty)
          SliverToBoxAdapter(
            child: SpaceTabNotice(
              error: error,
              loading: loading,
              retry: onRetry,
              empty: 'No members to show yet.',
            ),
          )
        else ...[
          SliverList.builder(
            itemCount: list.length,
            itemBuilder: (context, i) => _MemberRow(list[i], x.kind),
          ),
          if (hasMore)
            SliverToBoxAdapter(
              child: TextButton(
                onPressed: loading ? null : onMore,
                child: const Text('Show more members'),
              ),
            ),
          if (error != null)
            SliverToBoxAdapter(
              child: FailureCard(error: error!, retry: onRetry),
            ),
        ],
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  final SpaceMember m;
  final String kind;
  const _MemberRow(this.m, this.kind);
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(VibeRadius.small),
      onTap: () => openPerson(context, m.user.userId),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SpacePersonAvatar(m.user, radius: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.user.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    [
                      if (m.role == 'owner')
                        'Host'
                      else if (m.role != 'member')
                        spaceCapitalized(m.role),
                      if (m.user.username.isNotEmpty) '@${m.user.username}',
                      if (kind == 'event' && m.rsvp.isNotEmpty)
                        spaceCapitalized(m.rsvp),
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
