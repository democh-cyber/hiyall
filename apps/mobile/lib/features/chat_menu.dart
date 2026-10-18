import 'package:flutter/material.dart';

import '../shared/chat_tokens.dart';

/// What the conversation menu can do, in the order it lists them. Only
/// actions that exist: mute or unmute, pin or unpin, auto-translate (kept on this phone only), clear this
/// phone's history, delete the chat from the list (restorable for 30 days), open the profile, the safety
/// number (with whether it was verified), report (whose sheet also offers blocking) and block.
enum ChatMenuAction {
  mute,
  pin,
  autoTranslate,
  clearHistory,
  deleteChat,
  profile,
  safety,
  report,
  block,
}

/// Opens the conversation menu and returns the chosen action, or null.
Future<ChatMenuAction?> showChatSafetyMenu(
  BuildContext context, {
  required bool muted,
  required String peerName,
  bool verified = false,
  bool pinned = false,
  bool autoTranslate = false,
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
    builder: (context) => ChatSafetyMenu(
      muted: muted,
      peerName: peerName,
      verified: verified,
      pinned: pinned,
      autoTranslate: autoTranslate,
    ),
  );
}

/// The conversation menu: calm, grouped, and honest. Reporting sits apart, in
/// the error colour, so it is easy to find and hard to hit by accident.
class ChatSafetyMenu extends StatelessWidget {
  final bool muted;
  final String peerName;

  /// The person compared the safety number and nothing has changed since.
  final bool verified;

  /// This chat is pinned to the top of the list; auto-translate is on for it (this phone only).
  final bool pinned, autoTranslate;
  const ChatSafetyMenu({
    super.key,
    required this.muted,
    required this.peerName,
    this.verified = false,
    this.pinned = false,
    this.autoTranslate = false,
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
              key: const Key('chat-pin'),
              icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
              title: pinned ? 'Unpin chat' : 'Pin chat',
              subtitle: pinned
                  ? 'It goes back to its place by time.'
                  : 'Keeps it at the top of your chats. Up to 5.',
              onTap: () => Navigator.pop(context, ChatMenuAction.pin),
            ),
            _Tile(
              key: const Key('chat-auto-translate'),
              icon: Icons.translate_rounded,
              title: autoTranslate
                  ? 'Turn off auto-translate'
                  : 'Auto-translate',
              subtitle: autoTranslate
                  ? 'Their messages are translated on your phone.'
                  : 'Translate their messages on your phone. Kept only on this phone.',
              onTap: () => Navigator.pop(context, ChatMenuAction.autoTranslate),
            ),
            _Tile(
              key: const Key('chat-profile'),
              icon: Icons.person_outline_rounded,
              title: 'View $peerName’s profile',
              onTap: () => Navigator.pop(context, ChatMenuAction.profile),
            ),
            _Tile(
              key: const Key('chat-safety'),
              icon: verified
                  ? Icons.verified_user_rounded
                  : Icons.shield_outlined,
              title: 'Safety number',
              subtitle: verified
                  ? 'Verified. It shows again if their keys change.'
                  : 'Not verified. Compare it with $peerName in person.',
              onTap: () => Navigator.pop(context, ChatMenuAction.safety),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Divider(
                height: 1,
                color: t.hairline.withValues(alpha: .6),
              ),
            ),
            _Tile(
              key: const Key('chat-clear'),
              icon: Icons.cleaning_services_outlined,
              title: 'Clear history on this phone',
              subtitle: 'Removes the messages here. $peerName keeps theirs.',
              onTap: () => Navigator.pop(context, ChatMenuAction.clearHistory),
            ),
            _Tile(
              key: const Key('chat-delete'),
              icon: Icons.delete_outline_rounded,
              title: 'Delete chat',
              subtitle:
                  'Takes it out of your list. You can restore it for 30 days.',
              onTap: () => Navigator.pop(context, ChatMenuAction.deleteChat),
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
