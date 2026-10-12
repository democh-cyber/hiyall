import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart' show starPath;
import 'chat_parts.dart';
import 'chat_starters.dart';

/// The first-time state of a brand-new conversation: a small card, not a
/// hero, that can be dismissed and never blocks sending. It says hi to a
/// person by name, says what the two have in common when the server found
/// something (never invented here), offers three or four icebreakers that
/// only fill the composer, and says in one quiet line that reporting and
/// blocking are a tap away. Once the conversation has a message it is not shown.
class NewChatCard extends StatelessWidget {
  final String name, userId, conversationId;
  final String? avatarUrl;

  /// What both people list, from the server; empty when nothing is shared.
  final List<String> sharedInterests;
  final ValueChanged<String> onPick;
  final VoidCallback onDismiss, onReport, onBlock;
  const NewChatCard({
    super.key,
    required this.name,
    required this.userId,
    required this.conversationId,
    required this.avatarUrl,
    required this.onPick,
    required this.onDismiss,
    required this.onReport,
    required this.onBlock,
    this.sharedInterests = const [],
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final line = sharedInterestLine(sharedInterests);
    final starters = startersFor(conversationId, sharedInterests);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, box.maxHeight - 36),
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Container(
                key: const Key('conversation-empty'),
                padding: const EdgeInsets.fromLTRB(16, 14, 6, 6),
                decoration: BoxDecoration(
                  color: t.surface.withValues(alpha: t.isDark ? .85 : 1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: t.hairline.withValues(alpha: .55)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PersonAvatar(
                          name: name,
                          avatarUrl: avatarUrl,
                          userId: userId,
                          radius: 24,
                          initialStyle: const TextStyle(
                            fontFamily: 'SpaceGrotesk',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Say hi to $name 👋',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
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
                                if (line != null)
                                  Text(
                                    line,
                                    key: const Key('new-chat-shared'),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.3,
                                      fontWeight: FontWeight.w700,
                                      color: t.accent,
                                    ),
                                  )
                                else
                                  Text(
                                    'Pick an idea or write your own.',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      height: 1.3,
                                      color: t.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        ChatIconButton(
                          key: const Key('new-chat-dismiss'),
                          icon: Icons.close_rounded,
                          tooltip: 'Dismiss',
                          size: 44,
                          iconSize: 20,
                          color: t.textSecondary,
                          onTap: onDismiss,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Wrap(
                        key: const Key('new-chat-starters'),
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          for (final s in starters) _Starter(s, onPick),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Divider(
                        height: 1,
                        color: t.hairline.withValues(alpha: .6),
                      ),
                    ),
                    _SafetyLine(onReport: onReport, onBlock: onBlock),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Starter extends StatelessWidget {
  final String text;
  final ValueChanged<String> onPick;
  const _Starter(this.text, this.onPick);
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return PressScale(
      key: Key('starter-$text'),
      onTap: () => onPick(text),
      semanticLabel: 'Start with: $text',
      borderRadius: BorderRadius.circular(100),
      minHeight: 44,
      pressedScale: .97,
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: t.elevated,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: t.hairline.withValues(alpha: .5)),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// "You're in control: report or block anytime", with the two actions as small
/// text buttons. They call the same handlers as the conversation menu.
class _SafetyLine extends StatelessWidget {
  final VoidCallback onReport, onBlock;
  const _SafetyLine({required this.onReport, required this.onBlock});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    Widget action(Key key, String label, VoidCallback onTap) => PressScale(
      key: key,
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(100),
      minHeight: 44,
      pressedScale: .96,
      child: Center(
        widthFactor: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: t.accent,
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 4, 0),
      child: Wrap(
        key: const Key('new-chat-safety'),
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield_outlined, size: 15, color: t.textSecondary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'You’re in control: report or block anytime',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      color: t.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          action(const Key('new-chat-report'), 'Report', onReport),
          action(const Key('new-chat-block'), 'Block', onBlock),
        ],
      ),
    );
  }
}

/// What remains of the first-time state once it is dismissed: just the quiet
/// encryption chip at the top of an empty thread.
class QuietNewChat extends StatelessWidget {
  const QuietNewChat({super.key});
  @override
  Widget build(BuildContext context) => const Align(
    alignment: Alignment.topCenter,
    child: Padding(
      key: Key('conversation-empty-quiet'),
      padding: EdgeInsets.only(top: 20),
      child: EncryptedChip(),
    ),
  );
}

/// A calm loading state for the thread while history is being read.
class ThreadLoading extends StatelessWidget {
  const ThreadLoading({super.key});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    Widget bar(double w, bool mine) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: w,
        height: 40,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: bubbleSkeletonRadii(mine),
        ),
      ),
    );
    return Semantics(
      label: 'Loading messages',
      child: ExcludeSemantics(
        child: Padding(
          key: const Key('thread-loading'),
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Column(
            children: [
              bar(180, false),
              bar(120, false),
              bar(210, true),
              bar(90, true),
            ],
          ),
        ),
      ),
    );
  }
}

BorderRadius bubbleSkeletonRadii(bool mine) => BorderRadius.only(
  topLeft: const Radius.circular(20),
  topRight: const Radius.circular(20),
  bottomLeft: Radius.circular(mine ? 20 : 6),
  bottomRight: Radius.circular(mine ? 6 : 20),
);

/// The "waving smiley with a speech bubble" drawn for empty states. Static
/// vector art, in the same hand as the Activity illustration.
class HelloArt extends StatelessWidget {
  final double height;
  const HelloArt({super.key, this.height = 200});
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ExcludeSemantics(
      child: SizedBox(
        width: 360 * height / 240,
        height: height,
        child: CustomPaint(
          painter: _HelloPainter(
            Theme.of(context).brightness == Brightness.dark,
          ),
        ),
      ),
    ),
  );
}

class _HelloPainter extends CustomPainter {
  final bool dark;
  const _HelloPainter(this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / 360, size.height / 240);
    canvas.save();
    canvas.translate(
      (size.width - 360 * scale) / 2,
      (size.height - 240 * scale) / 2,
    );
    canvas.scale(scale);
    final ink = dark ? VibeColors.lilac : VibeColors.ink;
    canvas.drawCircle(
      const Offset(180, 120),
      112,
      Paint()
        ..shader = RadialGradient(
          colors: [
            VibeColors.lime.withValues(alpha: dark ? .07 : .22),
            VibeColors.lime.withValues(alpha: 0),
          ],
        ).createShader(const Rect.fromLTWH(68, 8, 224, 224)),
    );
    canvas.save();
    canvas.translate(180, 124);
    canvas.rotate(-.38);
    final line = Paint()
      ..color = ink.withValues(alpha: dark ? .25 : .22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 290, height: 130),
      line,
    );
    canvas.rotate(.82);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 240, height: 144),
      line,
    );
    canvas.restore();
    canvas.drawCircle(
      const Offset(98, 150),
      40,
      Paint()..color = VibeColors.peach,
    );
    final shape = Path()
      ..moveTo(157, 54)
      ..cubicTo(210, 30, 253, 77, 239, 127)
      ..cubicTo(234, 174, 195, 197, 151, 181)
      ..cubicTo(118, 159, 110, 81, 157, 54)
      ..close();
    canvas.drawPath(
      shape,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [VibeColors.lilac, Color(0xffbba2e4)],
        ).createShader(const Rect.fromLTWH(116, 42, 132, 146)),
    );
    final face = Paint()
      ..color = VibeColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(
      const Offset(171, 108),
      3.6,
      Paint()..color = VibeColors.ink,
    );
    canvas.drawCircle(
      const Offset(204, 108),
      3.6,
      Paint()..color = VibeColors.ink,
    );
    canvas.drawArc(
      const Rect.fromLTWH(164, 116, 48, 32),
      .15,
      math.pi - .3,
      false,
      face,
    );
    // The speech bubble carrying three dots.
    final bubble = RRect.fromRectAndRadius(
      const Rect.fromLTWH(236, 40, 70, 40),
      const Radius.circular(18),
    );
    canvas.drawRRect(bubble, Paint()..color = VibeColors.lime);
    canvas.drawPath(
      Path()
        ..moveTo(246, 76)
        ..lineTo(240, 94)
        ..lineTo(262, 79)
        ..close(),
      Paint()..color = VibeColors.lime,
    );
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(256 + i * 14.0, 60),
        3.6,
        Paint()..color = VibeColors.ink,
      );
    }
    canvas.drawPath(
      starPath(const Offset(78, 70), 10, 4),
      Paint()..color = VibeColors.pink,
    );
    canvas.drawPath(
      starPath(const Offset(274, 172), 7, 2.5),
      Paint()..color = ink.withValues(alpha: .6),
    );
    canvas.drawCircle(
      const Offset(52, 126),
      2.5,
      Paint()..color = ink.withValues(alpha: .45),
    );
    canvas.drawCircle(
      const Offset(310, 130),
      2,
      Paint()..color = ink.withValues(alpha: .45),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HelloPainter old) => dark != old.dark;
}
