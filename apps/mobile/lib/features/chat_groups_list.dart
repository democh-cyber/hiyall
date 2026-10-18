import 'dart:async';

import 'package:flutter/material.dart';

import '../core/chat/chat_api.dart' show ChatFailure;
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_groups.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';
import '../shared/widgets.dart' show showMessage;
import 'chat.dart' show chatError;
import 'chat_groups_data.dart';
import 'chat_parts.dart';

// What a group looks like in the Chats list: the stack of member photos with a small group mark, and the
// "Pending invites" section above the chats.

/// Up to three member photos, overlapping, in a square of [size]. Decorative: the row or header that holds it
/// says who is in the group and how many.
class GroupAvatarStack extends StatelessWidget {
  final List<GroupMember> members;
  final double size;

  /// The colour behind the stack, used for the thin ring that separates overlapping photos.
  final Color ring;
  const GroupAvatarStack({
    super.key,
    required this.members,
    required this.size,
    required this.ring,
  });

  @override
  Widget build(BuildContext context) {
    final shown = members.take(3).toList();
    final n = shown.length;
    // One photo fills the square; two or three are smaller and overlap.
    final d = n <= 1 ? size : size * (n == 2 ? .64 : .58);
    Widget face(GroupMember m) => Container(
      width: d,
      height: d,
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
      child: PersonAvatar(
        name: m.name,
        avatarUrl: m.avatarUrl,
        userId: m.userId,
        radius: (d - 3) / 2,
        initialStyle: const TextStyle(
          fontFamily: 'SpaceGrotesk',
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final spots = switch (n) {
      0 => const <Offset>[],
      1 => const [Offset.zero],
      2 => [Offset.zero, Offset(size - d, size - d)],
      _ => [
        Offset.zero,
        Offset(size - d, size * .08),
        Offset(size * .2, size - d),
      ],
    };
    return ExcludeSemantics(
      child: SizedBox(
        key: const Key('group-avatar-stack'),
        width: size,
        height: size,
        child: Stack(
          children: [
            // Painted back to front, so the first member is on top.
            for (var i = n - 1; i >= 0; i--)
              PositionedDirectional(
                start: spots[i].dx,
                top: spots[i].dy,
                child: face(shown[i]),
              ),
            if (n == 0)
              Center(
                child: Icon(
                  Icons.groups_rounded,
                  size: size * .6,
                  color: ChatTokens.of(context).textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The small group mark that sits on the corner of a group's photo stack.
class GroupMark extends StatelessWidget {
  final Color ring;
  const GroupMark({super.key, required this.ring});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Container(
      key: const Key('group-mark'),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: t.lime,
        border: Border.all(color: ring, width: 2),
      ),
      child: Icon(Icons.groups_rounded, size: 12, color: t.onLime),
    );
  }
}

/// The photo stack with the group mark, as the avatar of a row in the Chats list. No online dot: a group has no
/// presence.
class GroupRowAvatar extends StatelessWidget {
  final GroupInfo group;
  final String me;
  final Color ring;
  const GroupRowAvatar({
    super.key,
    required this.group,
    required this.me,
    required this.ring,
  });
  @override
  Widget build(BuildContext context) {
    const size = ChatMetrics.avatarRadius * 2;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GroupAvatarStack(
            members: stackMembers(group, me),
            size: size,
            ring: ring,
          ),
          PositionedDirectional(
            end: -4,
            bottom: -4,
            child: ExcludeSemantics(child: GroupMark(ring: ring)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------- pending invites

/// "Pending invites": one card per invitation, above the chats, only when there are any. Accept joins (the
/// encrypted join message goes out with it); Decline asks for no reason and tells nobody. An invite that
/// expired or was withdrawn disappears on the next refresh, or at once when the relay says so.
class PendingInvitesSection extends StatefulWidget {
  final ChatEngine engine;
  final List<GroupInvite> invites;

  /// Called after an answer, so the lists behind refresh.
  final VoidCallback onChanged;
  const PendingInvitesSection({
    super.key,
    required this.engine,
    required this.invites,
    required this.onChanged,
  });
  @override
  State<PendingInvitesSection> createState() => _PendingInvitesSectionState();
}

class _PendingInvitesSectionState extends State<PendingInvitesSection> {
  /// Invites being answered, and what went wrong with the last attempt on each.
  final _busy = <String, bool>{};
  final _errors = <String, String>{};

  /// Invites answered here, hidden before the refresh brings the new list.
  final _gone = <String>{};

  Future<void> _accept(GroupInvite invite) async {
    setState(() {
      _busy[invite.groupId] = true;
      _errors.remove(invite.groupId);
    });
    try {
      await widget.engine.acceptGroupInvite(invite.groupId);
      if (!mounted) return;
      setState(() => _gone.add(invite.groupId));
      showMessage(context, 'You joined ${inviteTitle(invite)}.');
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors[invite.groupId] = _inviteError(e));
      // An invite that is gone is gone: refresh so it disappears.
      if (e is ChatFailure && e.code == 'NOT_FOUND') widget.onChanged();
    } finally {
      if (mounted) setState(() => _busy.remove(invite.groupId));
    }
  }

  Future<void> _decline(GroupInvite invite) async {
    setState(() {
      _busy[invite.groupId] = true;
      _errors.remove(invite.groupId);
    });
    try {
      await widget.engine.declineGroupInvite(invite.groupId);
      if (!mounted) return;
      setState(() => _gone.add(invite.groupId));
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors[invite.groupId] = _inviteError(e));
      if (e is ChatFailure && e.code == 'NOT_FOUND') widget.onChanged();
    } finally {
      if (mounted) setState(() => _busy.remove(invite.groupId));
    }
  }

  String _inviteError(Object e) {
    if (e is ChatFailure && e.code == 'NOT_FOUND') {
      return 'This invite has expired or was withdrawn.';
    }
    return groupFailureText(e) ?? chatError(e);
  }

  @override
  Widget build(BuildContext context) {
    final invites = [
      for (final i in widget.invites)
        if (!_gone.contains(i.groupId)) i,
    ];
    if (invites.isEmpty) return const SizedBox.shrink();
    final t = ChatTokens.of(context);
    return Padding(
      key: const Key('pending-invites'),
      padding: const EdgeInsetsDirectional.fromSTEB(
        ChatMetrics.pagePadding,
        4,
        ChatMetrics.pagePadding,
        10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: clampedChrome(
              context,
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Pending invites',
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.2,
                    color: t.text,
                  ),
                ),
              ),
            ),
          ),
          for (final invite in invites)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _InviteCard(
                key: Key('invite-${invite.groupId}'),
                invite: invite,
                busy: _busy.containsKey(invite.groupId),
                error: _errors[invite.groupId],
                onAccept: () => unawaited(_accept(invite)),
                onDecline: () => unawaited(_decline(invite)),
              ),
            ),
        ],
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  final GroupInvite invite;
  final bool busy;
  final String? error;
  final VoidCallback onAccept, onDecline;
  const _InviteCard({
    super.key,
    required this.invite,
    required this.busy,
    required this.error,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final title = inviteTitle(invite);
    final by = displayName(invite.invitedBy.name);
    final count = memberCountText(invite.memberCount);
    final members = invite.members.isEmpty
        ? [invite.invitedBy]
        : invite.members;
    return Semantics(
      container: true,
      label: 'Group invite: $title. Invited by $by. $count.',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.hairline.withValues(alpha: .5)),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GroupAvatarStack(members: members, size: 44, ring: t.surface),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'SpaceGrotesk',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                              color: t.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Invited by $by',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 1.3,
                              color: t.textSecondary,
                            ),
                          ),
                          Text(
                            count,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              color: t.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      key: Key('invite-error-${invite.groupId}'),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        color: t.error,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    if (busy)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    TextButton(
                      key: Key('invite-decline-${invite.groupId}'),
                      onPressed: busy ? null : onDecline,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          ChatMetrics.hit,
                          ChatMetrics.hit,
                        ),
                        foregroundColor: t.textSecondary,
                      ),
                      child: Semantics(
                        label: 'Decline invite to $title',
                        excludeSemantics: true,
                        child: const Text('Decline'),
                      ),
                    ),
                    FilledButton(
                      key: Key('invite-accept-${invite.groupId}'),
                      onPressed: busy ? null : onAccept,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(
                          ChatMetrics.hit,
                          ChatMetrics.hit,
                        ),
                      ),
                      child: Semantics(
                        label: 'Accept invite to $title',
                        excludeSemantics: true,
                        child: const Text('Accept'),
                      ),
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
