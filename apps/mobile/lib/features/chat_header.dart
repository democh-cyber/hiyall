import 'package:flutter/material.dart';

import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';
import '../shared/presence_dot.dart';
import '../shared/press_scale.dart';
import 'chat_format.dart';
import 'chat_parts.dart';

/// Back, avatar, name (20 px, bold), one subtitle line, the safety shield (a
/// visible 48 dp control) and the menu, in 56 px. Its height never changes: the subtitle line is always
/// reserved, a long name ellipsizes, and large text is clamped.
class ChatHeader extends StatelessWidget {
  final String name, userId;
  final String? avatarUrl;
  final bool typing, muted, canAct;

  /// Presence as the server allowed this account to see it: online, or else
  /// when they were last seen (a five-minute bucket). Both absent means the
  /// subtitle falls back to the encryption line. [now] is the clock the
  /// last-seen text is measured against (the chat clock, replaced in tests).
  final bool online;
  final DateTime? lastSeenAt;
  final DateTime? now;
  final VoidCallback onBack, onSafety, onOptions;
  final VoidCallback? onProfile;

  /// A group's header: [leading] (the stack of member photos) replaces the person's photo, [subtitle] ("5
  /// members") replaces the presence line, [profileLabel] says what a tap opens (Group info), and there is no
  /// safety shield for one person (the safety numbers are per member in Group info). A group has no presence
  /// and no typing line.
  final Widget? leading;
  final String? subtitle, profileLabel;
  final bool showSafety;
  const ChatHeader({
    super.key,
    required this.name,
    required this.userId,
    required this.avatarUrl,
    required this.typing,
    required this.muted,
    required this.canAct,
    required this.onBack,
    required this.onSafety,
    required this.onOptions,
    required this.onProfile,
    this.online = false,
    this.lastSeenAt,
    this.now,
    this.leading,
    this.subtitle,
    this.profileLabel,
    this.showSafety = true,
  });

  static const height = ChatMetrics.headerHeight;

  /// The name is the loudest thing in the header; one line, ellipsized.
  static const nameSize = 20.0;

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    // On the narrowest phones the avatar gives a few pixels back to the name.
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return clampedChrome(
      context,
      DecoratedBox(
        decoration: BoxDecoration(
          color: t.bg,
          border: Border(
            bottom: BorderSide(color: t.hairline.withValues(alpha: .6)),
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: conversationMaxWidth,
              minHeight: height,
              maxHeight: height,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  ChatIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back to chats',
                    onTap: onBack,
                  ),
                  Expanded(
                    child: PressScale(
                      key: const Key('chat-header-profile'),
                      onTap: onProfile,
                      borderRadius: BorderRadius.circular(18),
                      semanticLabel: profileLabel ?? 'Open $name’s profile',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            if (leading != null)
                              leading!
                            else
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  PersonAvatar(
                                    name: name,
                                    avatarUrl: avatarUrl,
                                    userId: userId,
                                    radius: narrow ? 17 : 20,
                                    initialStyle: const TextStyle(
                                      fontFamily: 'SpaceGrotesk',
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (online)
                                    Positioned(
                                      right: -2,
                                      bottom: -2,
                                      child: PresenceDot(
                                        key: const Key('chat-online-dot'),
                                        size: 14,
                                        ringColor: t.bg,
                                      ),
                                    ),
                                ],
                              ),
                            const SizedBox(width: 10),
                            Expanded(child: _titles(context, t)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (muted)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Tooltip(
                        message: 'Muted',
                        child: Icon(
                          Icons.notifications_off_outlined,
                          key: const Key('chat-muted'),
                          size: 18,
                          color: t.textTertiary,
                        ),
                      ),
                    ),
                  if (showSafety)
                    SafetyShieldButton(
                      key: const Key('safety-number-button'),
                      onTap: canAct ? onSafety : null,
                    ),
                  ChatIconButton(
                    key: const Key('chat-options'),
                    icon: Icons.more_vert_rounded,
                    tooltip: 'Chat options',
                    onTap: canAct ? onOptions : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titles(BuildContext context, ChatTokens t) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        name,
        key: const Key('chat-header-name'),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'SpaceGrotesk',
          fontSize: nameSize,
          height: 1.15,
          fontWeight: FontWeight.w700,
          letterSpacing: -.3,
          color: t.text,
        ),
      ),
      SizedBox(
        key: const Key('chat-header-subtitle'),
        height: 18,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: subtitle != null
              ? Text(
                  subtitle!,
                  key: const Key('chat-header-members'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: t.textSecondary,
                  ),
                )
              : typing
              ? Text(
                  'typing…',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: t.accent,
                  ),
                )
              : online
              ? Text(
                  PresenceDot.label,
                  key: const Key('chat-header-online'),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: PresenceDot.textColor(t.brightness),
                  ),
                )
              : lastSeenAt != null
              // Shrinks a little on the narrowest phones instead of cutting the
              // time off ("last seen yest…" would say nothing).
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    lastSeenText(
                      lastSeenAt!,
                      now ?? DateTime.now(),
                      (time) => TimeOfDay.fromDateTime(time).format(context),
                    ),
                    key: const Key('chat-header-last-seen'),
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: t.textSecondary,
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_rounded, size: 11, color: t.textSecondary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'end-to-end encrypted',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: t.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    ],
  );
}

/// The safety and encryption control: a tonal circle with a filled shield in
/// the accent colour inside a 48 dp target, so it reads as a real control and
/// not a decoration. Opens the safety number.
class SafetyShieldButton extends StatelessWidget {
  final VoidCallback? onTap;
  const SafetyShieldButton({super.key, required this.onTap});

  static const label = 'Safety and encryption';

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Tooltip(
      message: label,
      child: PressScale(
        onTap: onTap,
        semanticLabel: label,
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          width: ChatMetrics.hit,
          height: ChatMetrics.hit,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.surface,
                border: Border.all(
                  color: t.hairline.withValues(alpha: t.isDark ? .8 : 1),
                ),
              ),
              child: Icon(
                Icons.verified_user_rounded,
                size: 22,
                color: onTap == null
                    ? t.accent.withValues(alpha: .4)
                    : t.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
