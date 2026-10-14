import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../shared/person_link.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';
import 'space_parts.dart';

/// Above the participant list: space summary, invite field, state filter and
/// the loading, error or empty state.
class SpaceMembersHeader extends StatelessWidget {
  final SocialSpace? space;
  final TextEditingController invite;
  final bool busy, hasMembers;
  final String state;
  final Object? error;
  final void Function(String user, String action) onAction;
  final ValueChanged<String> onState;
  final VoidCallback onRetry;
  const SpaceMembersHeader({
    super.key,
    required this.space,
    required this.invite,
    required this.busy,
    required this.hasMembers,
    required this.state,
    required this.error,
    required this.onAction,
    required this.onState,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final x = space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (x != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                SpaceKindBadge(x.kind, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        x.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${x.memberCount} of ${x.capacity} spots taken',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (x?.host == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: invite,
                    textInputAction: TextInputAction.send,
                    onSubmitted: busy
                        ? null
                        : (v) => onAction(v.trim(), 'invite'),
                    decoration: const InputDecoration(
                      labelText: 'Invite someone',
                      hintText: '@username',
                      prefixIcon: Icon(Icons.alternate_email_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Invite',
                  onPressed: busy
                      ? null
                      : () => onAction(invite.text.trim(), 'invite'),
                  icon: const Icon(Icons.person_add_outlined),
                ),
              ],
            ),
          ),
        if (x?.moderate == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final k in spaceMemberStates.entries)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: Text(k.value),
                        selected: k.key == state,
                        onSelected: busy ? null : (_) => onState(k.key),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (error != null) FailureCard(error: error!, retry: onRetry),
        if (busy && !hasMembers) const VibeLoading(),
        if (!busy && !hasMembers && error == null)
          EmptyCard(
            icon: Icons.people_outline_rounded,
            title: 'No one here',
            description: state == 'active'
                ? 'No participants in this list.'
                : 'No ${spaceMemberStates[state]!.toLowerCase()} right now.',
          ),
      ],
    );
  }
}

/// One participant with their role tag and, for moderators, a manage menu.
class SpaceMemberTile extends StatelessWidget {
  final SpaceMember member;
  final SocialSpace? space;

  /// The signed-in person, who cannot manage themselves.
  final String? meId;
  final void Function(String user, String action) onAction;
  const SpaceMemberTile({
    super.key,
    required this.member,
    required this.space,
    required this.meId,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final m = member, x = space;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: SpacePersonAvatar(m.user, radius: 22),
      title: Text(
        m.user.name,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        [
          if (m.user.username.isNotEmpty) '@${m.user.username}',
          if (x?.kind == 'event' && m.rsvp.isNotEmpty) spaceCapitalized(m.rsvp),
        ].join(' · '),
      ),
      onTap: () => openPerson(context, m.user.userId),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.role != 'member')
            VibeTag(
              m.role == 'owner' ? 'Host' : m.role,
              color: m.role == 'owner' ? VibeColors.lime : VibeColors.lilac,
            ),
          if (x?.moderate == true && m.role != 'owner' && m.user.userId != meId)
            PopupMenuButton<String>(
              tooltip: 'Manage',
              onSelected: (v) => onAction(m.user.userId, v),
              itemBuilder: (_) => [
                if (m.state == 'pending')
                  const PopupMenuItem(value: 'approve', child: Text('Approve')),
                if (m.state == 'banned')
                  const PopupMenuItem(value: 'unban', child: Text('Unban'))
                else ...[
                  const PopupMenuItem(value: 'remove', child: Text('Remove')),
                  const PopupMenuItem(value: 'ban', child: Text('Ban')),
                ],
                if (x?.host == true && m.state == 'active') ...[
                  const PopupMenuItem(
                    value: 'moderator',
                    child: Text('Make moderator'),
                  ),
                  const PopupMenuItem(
                    value: 'member',
                    child: Text('Make member'),
                  ),
                  if (x?.myRole == 'owner')
                    const PopupMenuItem(
                      value: 'admin',
                      child: Text('Make admin'),
                    ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
