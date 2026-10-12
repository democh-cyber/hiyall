import 'package:flutter/material.dart';

import '../core/chat/chat_engine.dart';
import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';
import '../shared/presence_dot.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart' show starPath;
import 'chat_format.dart';
import 'chat_thread.dart';

/// The widest the chat list grows; wider windows centre it.
const chatListMaxWidth = 680.0;

/// What the list says about a chat's last message, for rows and for screen
/// readers: "You: sounds good", "Photo", or the @handle before anything is sent.
String chatPreviewText(ChatConversation c) =>
    previewFor(c.last, username: c.peerUsername).line;

const _rowGap = 14.0;
const _rowInset = 8.0;
const _rowPad = 12.0;

/// One chat in the list: a flat row with the avatar, name and last message,
/// the relative time, unread counter and mute mark. No card and no border: a
/// hairline under the text separates rows, and a row with unread messages gets
/// a slightly brighter fill, a stronger name and a lime time and counter.
class ChatRow extends StatelessWidget {
  final ChatConversation chat;
  final DateTime now;
  final bool typing;
  final VoidCallback onTap;

  /// The hairline under the row; the last row of a list has none.
  final bool showDivider;
  const ChatRow({
    super.key,
    required this.chat,
    required this.now,
    required this.typing,
    required this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final c = chat;
    final unread = c.unreadCount > 0;
    final when = c.last == null || c.last!.notice
        ? null
        : chatListTime(c.last!.sentAt, now);
    final preview = previewFor(c.last, username: c.peerUsername);
    final label = [
      c.peerName,
      if (unread) '${c.unreadCount} unread',
      if (c.muted) 'muted',
      if (c.online) PresenceDot.label,
      if (typing) 'typing' else preview.line,
      ?when,
    ].join(', ');
    final previewColor = preview.isFailed
        ? t.error
        : unread
        ? t.text
        : t.textSecondary;

    final top = Row(
      children: [
        Expanded(
          child: Text(
            c.peerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 16.5,
              fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
              letterSpacing: -.25,
              height: 1.25,
              color: t.text,
            ),
          ),
        ),
        if (when != null) ...[
          const SizedBox(width: 10),
          clampedChrome(
            context,
            Text(
              when,
              key: Key('chat-time-${c.id}'),
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                color: unread ? t.accent : t.textTertiary,
              ),
            ),
          ),
        ],
      ],
    );

    final bottom = Row(
      children: [
        Expanded(
          child: typing
              ? Text(
                  'typing…',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: t.accent,
                  ),
                )
              : Row(
                  children: [
                    if (preview.isPhoto || preview.isFailed) ...[
                      Icon(
                        preview.isFailed
                            ? Icons.error_outline_rounded
                            : Icons.photo_camera_outlined,
                        size: 15,
                        color: previewColor,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        preview.line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.3,
                          fontWeight: unread
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: previewColor,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        if (unread || c.muted) ...[
          const SizedBox(width: 10),
          clampedChrome(
            context,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.muted)
                  Padding(
                    padding: EdgeInsets.only(right: unread ? 6 : 0),
                    child: Icon(
                      Icons.notifications_off_outlined,
                      key: Key('muted-${c.id}'),
                      semanticLabel: 'Muted',
                      size: 17,
                      color: t.textTertiary,
                    ),
                  ),
                if (unread)
                  UnreadBadge(count: c.unreadCount, muted: c.muted, id: c.id),
              ],
            ),
          ),
        ],
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _rowInset),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: unread ? t.unreadRow : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: PressScale(
              onTap: onTap,
              semanticLabel: label,
              borderRadius: BorderRadius.circular(18),
              pressedScale: .98,
              minHeight: ChatMetrics.rowMinHeight,
              highlight: t.text.withValues(alpha: .07),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _rowPad,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        PersonAvatar(
                          name: c.peerName,
                          avatarUrl: c.peerAvatarUrl,
                          userId: c.peerId,
                          radius: ChatMetrics.avatarRadius,
                          initialStyle: const TextStyle(
                            fontFamily: 'SpaceGrotesk',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        // Only when the server said they are online and let
                        // this account see it; never an "offline" mark.
                        if (c.online)
                          Positioned(
                            right: -1,
                            bottom: -1,
                            child: PresenceDot(
                              key: Key('chat-row-online-${c.peerId}'),
                              ringColor: unread ? t.unreadRow : t.bg,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: _rowGap),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [top, const SizedBox(height: 3), bottom],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showDivider)
          Padding(
            padding: EdgeInsets.only(
              left:
                  _rowInset + _rowPad + ChatMetrics.avatarRadius * 2 + _rowGap,
              right: ChatMetrics.pagePadding,
            ),
            child: Divider(
              key: Key('chat-divider-${c.id}'),
              height: 1,
              thickness: 1,
              color: t.hairline.withValues(alpha: .55),
            ),
          ),
      ],
    );
  }
}

/// The count of unread messages: lime where the chat can call for attention,
/// a quiet neutral pill when it is muted, "99+" above 99.
class UnreadBadge extends StatelessWidget {
  final int count;
  final bool muted;
  final String id;
  const UnreadBadge({
    super.key,
    required this.count,
    required this.muted,
    required this.id,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final duration = VibeMotion.duration(context);
    return TweenAnimationBuilder<double>(
      duration: duration,
      curve: Curves.easeOutCubic,
      tween: Tween(begin: .8, end: 1),
      builder: (context, v, child) => Transform.scale(scale: v, child: child),
      child: Container(
        key: Key('unread-$id'),
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: muted ? t.mutedBadgeFill : t.badgeFill,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          badgeCount(count),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: muted ? t.mutedBadgeInk : t.badgeInk,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

/// "Chats" and, under it, what is actually going on: "3 unread chats" or
/// "All caught up". Wide layouts already print the title in the app shell.
class ChatsHeading extends StatelessWidget {
  final String? subtitle;
  final bool showTitle;
  const ChatsHeading({
    super.key,
    required this.subtitle,
    this.showTitle = true,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final unread = subtitle != null && subtitle!.contains('unread');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ChatMetrics.pagePadding,
        4,
        ChatMetrics.pagePadding,
        14,
      ),
      // The heading scales with the system text size, up to a point.
      child: clampedChrome(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showTitle)
              Text(
                'Chats',
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 30,
                  height: 1.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.1,
                  color: t.text,
                ),
              ),
            ConstrainedBox(
              key: const Key('chats-subtitle'),
              constraints: const BoxConstraints(minHeight: 22),
              child: Align(
                alignment: Alignment.centerLeft,
                child: subtitle == null
                    ? null
                    : Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: unread
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: unread ? t.accent : t.textSecondary,
                        ),
                      ),
              ),
            ),
          ],
        ),
        1.4,
      ),
    );
  }
}

/// The search pill above the list: an elevated charcoal surface with no
/// visible edge until it is focused, when a soft lime ring appears. The caller
/// debounces [onChanged]; clearing is immediate.
class ChatSearchField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const ChatSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
  });
  @override
  State<ChatSearchField> createState() => _ChatSearchFieldState();
}

class _ChatSearchFieldState extends State<ChatSearchField> {
  final focus = FocusNode();
  bool focused = false;

  void _focusChanged() {
    if (mounted && focused != focus.hasFocus) {
      setState(() => focused = focus.hasFocus);
    }
  }

  @override
  void initState() {
    super.initState();
    focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    focus.removeListener(_focusChanged);
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return clampedChrome(context, _surface(context, t));
  }

  Widget _surface(BuildContext context, ChatTokens t) {
    return AnimatedContainer(
      key: const Key('chat-search-surface'),
      duration: VibeMotion.duration(context),
      constraints: const BoxConstraints(minHeight: ChatMetrics.searchHeight),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: focused ? t.focusRing : t.hairline.withValues(alpha: .4),
          width: focused ? 1.5 : 1,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: t.focusRing.withValues(alpha: .12),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          Icon(
            Icons.search_rounded,
            size: 22,
            color: focused ? t.accent : t.textSecondary,
          ),
          Expanded(
            child: TextField(
              key: const Key('chat-search'),
              controller: widget.controller,
              focusNode: focus,
              onChanged: widget.onChanged,
              textInputAction: TextInputAction.search,
              cursorColor: t.accent,
              style: TextStyle(fontSize: 16, height: 1.25, color: t.text),
              decoration: InputDecoration(
                hintText: 'Search conversations',
                hintStyle: TextStyle(
                  color: t.textSecondary,
                  fontSize: 16,
                  height: 1.25,
                ),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 13,
                ),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (context, v, _) => v.text.isEmpty
                ? const SizedBox(width: 8)
                : ChatIconButton(
                    key: const Key('chat-search-clear'),
                    icon: Icons.close_rounded,
                    tooltip: 'Clear search',
                    size: 44,
                    color: t.textSecondary,
                    onTap: () {
                      widget.controller.clear();
                      widget.onChanged('');
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// "All" and "Unread" (with how many), the only filters real data backs.
class ChatFilterChips extends StatelessWidget {
  final ChatFilter filter;
  final int unread;
  final ValueChanged<ChatFilter> onChanged;
  const ChatFilterChips({
    super.key,
    required this.filter,
    required this.unread,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      ChatMetrics.pagePadding,
      4,
      ChatMetrics.pagePadding,
      4,
    ),
    child: Wrap(
      spacing: 8,
      children: [
        _chip(context, ChatFilter.all, 'All', const Key('chat-filter-all')),
        _chip(
          context,
          ChatFilter.unread,
          unread > 0 ? 'Unread · $unread' : 'Unread',
          const Key('chat-filter-unread'),
        ),
      ],
    ),
  );

  Widget _chip(BuildContext context, ChatFilter value, String text, Key key) {
    final t = ChatTokens.of(context);
    final selected = filter == value;
    return PressScale(
      key: key,
      onTap: () => onChanged(value),
      semanticLabel: text,
      selected: selected,
      minHeight: 44,
      pressedScale: .97,
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: AnimatedContainer(
          duration: VibeMotion.duration(context),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected ? t.lime : t.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : t.hairline.withValues(alpha: .5),
            ),
          ),
          child: Center(
            widthFactor: 1,
            child: clampedChrome(
              context,
              Text(
                text,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: selected ? t.onLime : t.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The signature entry to meeting people: compact, lime-tinted, one action.
/// It opens Discover; nothing is matched for anyone.
class MeetSomeoneCard extends StatelessWidget {
  final VoidCallback onTap;
  const MeetSomeoneCard({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ChatMetrics.pagePadding,
        8,
        ChatMetrics.pagePadding,
        10,
      ),
      child: PressScale(
        key: const Key('meet-card'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        pressedScale: .98,
        semanticLabel: 'Meet someone new. Find people who share your vibe. Start exploring.',
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                t.lime.withValues(alpha: t.isDark ? .17 : .42),
                VibeColors.lilac.withValues(alpha: t.isDark ? .1 : .5),
              ],
            ),
            border: Border.all(
              color: t.lime.withValues(alpha: t.isDark ? .22 : .6),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Meet someone new',
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 18,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.4,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Find people who share your vibe',
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.3,
                        color: t.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Start exploring →',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: t.accent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: CustomPaint(painter: _OrbitPainter(t)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two crossing orbits around a lime dot with a small star: the same shapes as
/// the Discover tab icon, as a quiet signature rather than an illustration.
class _OrbitPainter extends CustomPainter {
  final ChatTokens t;
  const _OrbitPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final line = Paint()
      ..color = (t.isDark ? t.lavender : t.accent).withValues(alpha: .5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-.5);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 52, height: 24),
      line,
    );
    canvas.rotate(1.05);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 46, height: 22),
      line,
    );
    canvas.restore();
    canvas.drawCircle(c, 9, Paint()..color = t.lime);
    canvas.drawPath(starPath(c, 7, 2.8), Paint()..color = VibeColors.ink);
    canvas.drawCircle(
      c.translate(19, -15),
      2.6,
      Paint()..color = t.isDark ? t.lavender : t.accent,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.t != t;
}

/// A centred message with art or an icon and up to two actions. Used for the
/// empty list, no search results and the setup states.
class ChatMessageCard extends StatelessWidget {
  final Widget? art;
  final IconData? icon;
  final String title, body;
  final String? primaryLabel, secondaryLabel;
  final VoidCallback? onPrimary, onSecondary;

  /// Fills a bounded area and scrolls when large text does not fit it.
  final bool scrollable;
  const ChatMessageCard({
    super.key,
    this.scrollable = false,
    this.art,
    this.icon,
    required this.title,
    required this.body,
    this.primaryLabel,
    this.secondaryLabel,
    this.onPrimary,
    this.onSecondary,
  });
  @override
  Widget build(BuildContext context) {
    final card = _card(context);
    if (!scrollable) return card;
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: card,
        ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final t = ChatTokens.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?art,
              if (icon != null)
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: t.hairline.withValues(alpha: .6)),
                  ),
                  child: Icon(icon, size: 32, color: t.accent),
                ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontSize: 25, height: 1.2, color: t.text),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: t.textSecondary,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              if (primaryLabel != null || secondaryLabel != null)
                const SizedBox(height: 22),
              if (primaryLabel != null)
                FilledButton(
                  key: const Key('chat-primary'),
                  style: FilledButton.styleFrom(
                    overlayColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                  ),
                  onPressed: onPrimary,
                  child: Text(primaryLabel!),
                ),
              if (secondaryLabel != null) ...[
                const SizedBox(height: 6),
                TextButton(
                  key: const Key('chat-secondary'),
                  style: TextButton.styleFrom(
                    foregroundColor: t.textSecondary,
                    overlayColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                  ),
                  onPressed: onSecondary,
                  child: Text(secondaryLabel!, textAlign: TextAlign.center),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder rows while the chats load. Still, so it can't keep a test or a
/// reduced-motion user waiting on an animation.
class ChatListSkeleton extends StatelessWidget {
  const ChatListSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final fill = t.surface;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(h / 2),
      ),
    );
    return Semantics(
      label: 'Loading chats…',
      child: ExcludeSemantics(
        child: Column(
          key: const Key('chats-loading'),
          children: [
            for (var i = 0; i < 6; i++)
              Container(
                height: ChatMetrics.rowMinHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: _rowInset + _rowPad,
                ),
                child: Row(
                  children: [
                    Container(
                      width: ChatMetrics.avatarRadius * 2,
                      height: ChatMetrics.avatarRadius * 2,
                      decoration: BoxDecoration(
                        color: fill,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: _rowGap),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(110 + (i % 3) * 36, 13),
                          const SizedBox(height: 10),
                          bar(190 - (i % 2) * 50, 11),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Loading chats…'),
            ),
          ],
        ),
      ),
    );
  }
}
