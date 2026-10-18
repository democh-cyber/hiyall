import 'package:flutter/material.dart';

import '../core/chat/chat_groups.dart';
import '../shared/chat_tokens.dart';
import 'chat_groups_data.dart';
import 'chat_groups_list.dart';
import 'chat_parts.dart';

// The pieces of a group's thread that differ from a one-to-one one: the header's photo stack, the calm line in
// place of the composer, and the empty thread.

/// The stack of member photos in a group's header (decorative; the header's own label says who and how many).
class GroupHeaderAvatar extends StatelessWidget {
  final GroupInfo? group;
  final String me;
  const GroupHeaderAvatar({super.key, required this.group, required this.me});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final g = group;
    return GroupAvatarStack(
      members: g == null ? const [] : stackMembers(g, me),
      size: narrow ? 34 : 40,
      ring: t.bg,
    );
  }
}

/// What the header says to a screen reader: "Group info, weekend crew, 5 members".
String groupHeaderLabel(String title, int members) =>
    'Group info, $title, ${memberCountText(members)}';

/// In place of the composer when nothing can be sent: the group was left, closed, or this account was removed, or
/// it is still waiting for the others to join. One calm line.
class GroupComposerNotice extends StatelessWidget {
  final String text;
  const GroupComposerNotice(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: conversationMaxWidth),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 12, 10),
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Container(
                key: const Key('group-composer-notice'),
                constraints: const BoxConstraints(
                  minHeight: ChatMetrics.composerMinHeight - 3,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: t.hairline.withValues(alpha: .6)),
                ),
                child: clampedChrome(
                  context,
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: t.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          text,
                          style: TextStyle(
                            fontSize: 14.5,
                            height: 1.3,
                            color: t.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A group thread with no messages yet.
class GroupThreadStart extends StatelessWidget {
  final bool canSend;
  const GroupThreadStart({super.key, required this.canSend});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.groups_rounded, size: 40, color: t.accent),
                  const SizedBox(height: 12),
                  Text(
                    'No messages yet',
                    key: const Key('group-empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: t.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    canSend
                        ? 'Say hello to the group. People who join later don’t see what was sent before.'
                        : 'People who join later don’t see what was sent before.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.4,
                      color: t.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const EncryptedChip(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
