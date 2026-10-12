import 'package:flutter/material.dart';

import '../shared/chat_tokens.dart';

/// What the conversation menu can do, in the order it lists them. Only
/// actions that exist: mute or unmute, open the profile, report (whose sheet
/// also offers blocking) and block.
enum ChatMenuAction { mute, profile, report, block }

/// Opens the conversation menu and returns the chosen action, or null.
Future<ChatMenuAction?> showChatSafetyMenu(
  BuildContext context, {
  required bool muted,
  required String peerName,
}) {
  final t = ChatTokens.of(context);
  return showModalBottomSheet<ChatMenuAction>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: t.bg2,
    barrierColor: Colors.black.withValues(alpha: t.isDark ? .6 : .35),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => ChatSafetyMenu(muted: muted, peerName: peerName),
  );
}

/// The conversation menu: calm, grouped, and honest. Reporting sits apart, in
/// the error colour, so it is easy to find and hard to hit by accident.
class ChatSafetyMenu extends StatelessWidget {
  final bool muted;
  final String peerName;
  const ChatSafetyMenu({
    super.key,
    required this.muted,
    required this.peerName,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Tile(
              key: const Key('chat-mute'),
              icon: muted
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              title: muted ? 'Unmute chat' : 'Mute chat',
              subtitle:
                  'No notifications, and it stays out of your unread count.',
              onTap: () => Navigator.pop(context, ChatMenuAction.mute),
            ),
            _Tile(
              key: const Key('chat-profile'),
              icon: Icons.person_outline_rounded,
              title: 'View $peerName’s profile',
              onTap: () => Navigator.pop(context, ChatMenuAction.profile),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Divider(
                height: 1,
                color: t.hairline.withValues(alpha: .6),
              ),
            ),
            _Tile(
              key: const Key('chat-report'),
              icon: Icons.flag_outlined,
              title: 'Report',
              subtitle: 'Tell us what is wrong. You can also block from there.',
              danger: true,
              onTap: () => Navigator.pop(context, ChatMenuAction.report),
            ),
            _Tile(
              key: const Key('chat-block'),
              icon: Icons.block_rounded,
              title: 'Block $peerName',
              subtitle: 'They can’t message you, and the chat closes.',
              danger: true,
              onTap: () => Navigator.pop(context, ChatMenuAction.block),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool danger;
  final VoidCallback onTap;
  const _Tile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final ink = danger ? t.error : t.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: danger ? t.error.withValues(alpha: .14) : t.surface,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 21, color: ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.3,
                            color: t.textSecondary,
                          ),
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
