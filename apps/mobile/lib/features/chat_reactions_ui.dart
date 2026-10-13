import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../core/chat/chat_attachment.dart' show SendStatus;
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_reactions.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import 'chat_parts.dart';

// Reactions and replies in the conversation: the floating menu, the chips
// under a bubble, the quote inside one, the "Replying to" bar and the small
// notice for a reaction that could not be sent. The wire format and the rules
// are in docs/security/13-encrypted-chat-implementation.md.

/// Emoji fonts named explicitly so reactions draw in colour wherever the
/// platform's own fallback would pick a different one; the platform still
/// falls back on its own after these.
const emojiFonts = ['Apple Color Emoji', 'Noto Color Emoji'];

/// What the bubbles can do. The screen supplies it; a null value (a bubble in
/// a test or a preview) leaves the bubble inert.
class BubbleActions {
  /// Sets this account's reaction to the message, or clears it with null.
  final Future<void> Function(ChatMessage message, String? emoji) onReact;

  /// Starts a reply to the message.
  final void Function(ChatMessage message) onReply;

  /// Scrolls to a quoted message if it is loaded; does nothing otherwise.
  final void Function(String messageId) onQuoteTap;

  /// Copies the message's text.
  final void Function(ChatMessage message) onCopy;
  const BubbleActions({
    required this.onReact,
    required this.onReply,
    required this.onQuoteTap,
    required this.onCopy,
  });
}

/// Whether a message can be reacted to or replied to: delivered, a real
/// message (not a notice) and addressable by its id.
bool canInteract(ChatMessage m) =>
    !m.notice && m.status == SendStatus.sent && m.messageId.length == 36;

// ------------------------------------------------------------------ chips

/// One chip under a bubble: an emoji, and who is behind it.
class ReactionChipData {
  final String emoji;
  final bool mine, theirs;
  const ReactionChipData(
    this.emoji, {
    required this.mine,
    required this.theirs,
  });

  /// The count shows only when both people chose the same emoji.
  int get count => (mine ? 1 : 0) + (theirs ? 1 : 0);
}

/// The chips of [m]: this account's first, then the others in picker order.
List<ReactionChipData> reactionChips(ChatMessage m, String selfId) {
  final byEmoji = <String, ReactionChipData>{};
  m.reactions.forEach((sender, emoji) {
    final mine = sender == selfId;
    final old = byEmoji[emoji];
    byEmoji[emoji] = ReactionChipData(
      emoji,
      mine: mine || (old?.mine ?? false),
      theirs: !mine || (old?.theirs ?? false),
    );
  });
  final all = byEmoji.values.toList();
  int rank(ReactionChipData c) =>
      (c.mine ? -100 : 0) + reactionEmojis.indexOf(c.emoji);
  all.sort((a, b) => rank(a).compareTo(rank(b)));
  return all;
}

/// What a screen reader says for a chip.
String reactionChipLabel(ReactionChipData chip, String peerName) {
  final who = chip.mine && chip.theirs
      ? 'You and $peerName'
      : chip.mine
      ? 'You'
      : peerName;
  return '$who reacted with ${chip.emoji}';
}

/// The reactions under a bubble. Tapping this account's own chip removes its
/// reaction. The row is a normal part of the layout (it never sits over the
/// bubble or its time) and wraps inside the bubble's own maximum width.
class ReactionChips extends StatelessWidget {
  final List<ReactionChipData> chips;
  final String peerName;
  final bool alignEnd;
  final void Function(String emoji)? onRemoveMine;
  const ReactionChips({
    super.key,
    required this.chips,
    required this.peerName,
    required this.alignEnd,
    this.onRemoveMine,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Wrap(
      key: const Key('reaction-chips'),
      alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
      spacing: 6,
      children: [
        for (final chip in chips)
          _Chip(
            key: Key('chip-${chip.emoji}'),
            chip: chip,
            tokens: t,
            label: reactionChipLabel(chip, peerName),
            onTap: chip.mine && onRemoveMine != null
                ? () => onRemoveMine!(chip.emoji)
                : null,
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final ReactionChipData chip;
  final ChatTokens tokens;
  final String label;
  final VoidCallback? onTap;
  const _Chip({
    super.key,
    required this.chip,
    required this.tokens,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final still = MediaQuery.disableAnimationsOf(context);
    Widget face = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: chip.mine
            ? t.accent.withValues(alpha: t.isDark ? .2 : .14)
            : t.surface,
        border: Border.all(
          color: chip.mine
              ? t.accent
              : t.hairline.withValues(alpha: t.isDark ? .9 : 1),
          width: chip.mine ? 1.5 : 1,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 32,
          maxHeight: 32,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            widthFactor: 1,
            child: clampedChrome(
              context,
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    chip.emoji,
                    style: const TextStyle(
                      fontSize: 17,
                      height: 1.15,
                      fontFamilyFallback: emojiFonts,
                    ),
                  ),
                  if (chip.count > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '${chip.count}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                        color: t.text,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!still) {
      // A chip settles in with a small overshoot when it first appears.
      face = TweenAnimationBuilder<double>(
        tween: Tween(begin: .6, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        builder: (context, v, child) => Transform.scale(scale: v, child: child),
        child: face,
      );
    }
    // 48 dp of height, whatever the chip looks like.
    final target = ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ChatMetrics.hit,
        minWidth: ChatMetrics.hit,
      ),
      child: Center(widthFactor: 1, child: face),
    );
    if (onTap == null) {
      return Semantics(
        container: true,
        label: label,
        excludeSemantics: true,
        child: target,
      );
    }
    return Semantics(
      container: true,
      button: true,
      label: label,
      hint: 'Double tap to remove your reaction',
      excludeSemantics: true,
      onTap: onTap,
      child: PressScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        pressedScale: .92,
        child: target,
      ),
    );
  }
}

// ------------------------------------------------------------------ quote

/// Who a quote is attributed to, as the person reads it.
String quoteWho(
  ChatReply reply,
  ChatMessage? original,
  String selfId,
  String peerName,
) {
  final by = original == null
      ? reply.by
      : (original.mine ? selfId : original.senderId);
  return by == selfId ? 'You' : peerName;
}

/// How wide a quote wants to be for [who] and [line]: its text, the bar and
/// padding, kept between 120 and 260 dp.
double quoteNaturalWidth(
  BuildContext context,
  String who,
  String line,
  bool image,
) {
  final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
  double measure(String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  final name = measure(
    who,
    const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
  );
  final text = measure(line, const TextStyle(fontSize: 13.5));
  return (3.5 + 8 + 10 + math.max(name, (image ? 19 : 0) + text)).clamp(
    120.0,
    260.0,
  );
}

/// What a quote shows on its line: the snippet, or "Photo" for an image.
String quoteLine(ChatReply reply) => reply.isImage ? 'Photo' : reply.snippet;

/// A quote ready to draw: who, one line, whether it is a photo, and the id of
/// the original when it is loaded (what a tap scrolls to), else null.
class QuoteData {
  final String who, line;
  final bool image;
  final String? jumpTo;
  const QuoteData({
    required this.who,
    required this.line,
    required this.image,
    this.jumpTo,
  });
}

/// The quote at the top of a reply bubble: an accent bar, the author and one
/// line of what they said. A quote is attributed text, not proof; when the
/// original is in this device's history the caller passes the local text.
class QuoteBlock extends StatelessWidget {
  final String who, line;
  final bool image, onOutgoing;

  /// Fill the width the parent gives (the bubble's), instead of hugging the
  /// quoted text.
  final bool fill;
  final VoidCallback? onTap;
  const QuoteBlock({
    super.key,
    required this.who,
    required this.line,
    required this.image,
    required this.onOutgoing,
    this.fill = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final ink = onOutgoing ? t.outgoingInk : t.incomingInk;
    final bar = onOutgoing ? t.outgoingInk.withValues(alpha: .55) : t.accent;
    final tint = onOutgoing
        ? Colors.black.withValues(alpha: .08)
        : (t.isDark ? Colors.white : Colors.black).withValues(alpha: .07);
    final face = Container(
      constraints: fill
          ? null
          : const BoxConstraints(maxWidth: 260, minWidth: 120),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3.5, color: bar),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 5, 10, 6),
                child: clampedChrome(
                  context,
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: onOutgoing ? t.outgoingInk : t.accent,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (image) ...[
                            Icon(
                              Icons.photo_camera_outlined,
                              size: 14,
                              color: ink.withValues(alpha: .8),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.25,
                                color: ink.withValues(alpha: .85),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      container: true,
      button: onTap != null,
      label: 'Replying to $who: $line',
      excludeSemantics: true,
      onTap: onTap,
      child: onTap == null
          ? face
          : GestureDetector(
              key: const Key('quote-block'),
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: face,
            ),
    );
  }
}

// -------------------------------------------------------------- reply bar

/// "Replying to Mira" above the composer, with the quoted line and a close
/// button. Cancelling touches nothing else the person typed.
class ReplyBar extends StatelessWidget {
  final String who, line;
  final bool image;
  final VoidCallback onCancel;
  const ReplyBar({
    super.key,
    required this.who,
    required this.line,
    required this.image,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Container(
        key: const Key('reply-bar'),
        decoration: BoxDecoration(
          color: t.elevated,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: t.hairline.withValues(alpha: t.isDark ? .5 : 1),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: t.accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
                  child: Semantics(
                    container: true,
                    label: 'Replying to $who: $line',
                    excludeSemantics: true,
                    child: clampedChrome(
                      context,
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Replying to $who',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: t.accent,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (image) ...[
                                Icon(
                                  Icons.photo_camera_outlined,
                                  size: 15,
                                  color: t.textSecondary,
                                ),
                                const SizedBox(width: 5),
                              ],
                              Expanded(
                                child: Text(
                                  line,
                                  key: const Key('reply-bar-line'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.25,
                                    color: t.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ChatIconButton(
                key: const Key('reply-cancel'),
                icon: Icons.close_rounded,
                tooltip: 'Cancel reply',
                onTap: onCancel,
                color: t.textSecondary,
                iconSize: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- inline notice

/// A small notice above the composer, for a reaction that could not be sent.
/// It clears itself; it is never a blocking state and the screen keeps the
/// reaction taken back, so there is nothing to undo.
class ChatInlineNotice extends StatelessWidget {
  final String text;
  final VoidCallback? onRetry;
  final VoidCallback onDismiss;
  const ChatInlineNotice({
    super.key,
    required this.text,
    required this.onDismiss,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Container(
          key: const Key('chat-inline-notice'),
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.only(left: 14, right: 4),
          decoration: BoxDecoration(
            color: t.elevated,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: t.error.withValues(alpha: .6)),
          ),
          child: clampedChrome(
            context,
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 18, color: t.error),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onDismiss,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        text,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.25,
                          color: t.text,
                        ),
                      ),
                    ),
                  ),
                ),
                if (onRetry != null)
                  PressScale(
                    key: const Key('inline-notice-retry'),
                    onTap: onRetry,
                    semanticLabel: 'Try again',
                    borderRadius: BorderRadius.circular(24),
                    minHeight: ChatMetrics.hit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      child: Text(
                        'Retry',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: t.accent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------- bubble gestures

/// Wraps a bubble row with the touch and pointer behaviour of reactions and
/// replies: long press (or right click) opens the menu, a double tap toggles a
/// heart, and a swipe to the right starts a reply. The same three are offered
/// to screen readers as custom actions.
///
/// [builder] draws the bubble and receives the key of the bubble itself (so the
/// menu can cut a hole around it) and the semantic actions for its node.
class BubbleInteractions extends StatefulWidget {
  final ChatMessage message;
  final String selfId;
  final BubbleActions actions;

  /// Heart on double tap; off for photos, where a tap opens the viewer.
  final bool doubleTapHeart;
  final bool alignEnd;
  final Widget Function(
    BuildContext context,
    GlobalKey bubbleKey,
    Map<CustomSemanticsAction, VoidCallback> semanticActions,
  )
  builder;
  const BubbleInteractions({
    super.key,
    required this.message,
    required this.selfId,
    required this.actions,
    required this.builder,
    this.doubleTapHeart = true,
    this.alignEnd = false,
  });

  /// How far a swipe must travel to count as "reply", and how far the row
  /// follows the finger.
  static const replyThreshold = 56.0;
  static const maxShift = 30.0;

  @override
  State<BubbleInteractions> createState() => _BubbleInteractionsState();
}

class _BubbleInteractionsState extends State<BubbleInteractions>
    with SingleTickerProviderStateMixin {
  final _bubbleKey = GlobalKey();
  double _drag = 0;
  bool _armed = false;
  int _pops = 0;
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(() => setState(() => _drag = _from * (1 - _back.value)));
  double _from = 0;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  ChatMessage get m => widget.message;
  String? get _mine => m.reactions[widget.selfId];

  Future<void> _toggleHeart() async {
    final next = _mine == quickReaction ? null : quickReaction;
    if (next != null && mounted) setState(() => _pops++);
    await widget.actions.onReact(m, next);
  }

  Rect? _anchor() {
    final box = _bubbleKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// A message half under the header or the composer is scrolled fully into
  /// the thread first, so the menu has the whole message to sit beside.
  Future<void> _bringIntoView() async {
    final context = _bubbleKey.currentContext;
    if (context == null) return;
    final scrollable = Scrollable.maybeOf(context);
    final viewport = scrollable?.context.findRenderObject();
    final bubble = context.findRenderObject();
    if (scrollable == null ||
        viewport is! RenderBox ||
        bubble is! RenderBox ||
        !viewport.attached ||
        !bubble.attached) {
      return;
    }
    final view = viewport.localToGlobal(Offset.zero) & viewport.size;
    final rect = bubble.localToGlobal(Offset.zero) & bubble.size;
    const margin = 12.0;
    if (rect.height > view.height - 2 * margin) return;
    var dy = 0.0;
    if (rect.top < view.top + margin) {
      dy = rect.top - (view.top + margin);
    } else if (rect.bottom > view.bottom - margin) {
      dy = rect.bottom - (view.bottom - margin);
    }
    if (dy == 0) return;
    final position = scrollable.position;
    position.jumpTo(
      (position.pixels + dy).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _openMenu() async {
    await _bringIntoView();
    if (!mounted) return;
    final anchor = _anchor();
    if (anchor == null) return;
    unawaited(_tick());
    final choice = await showReactionMenu(
      context,
      anchor: anchor,
      mine: _mine,
      alignEnd: widget.alignEnd,
      canCopy: m.text.trim().isNotEmpty && !m.isPhoto,
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case MenuReact(:final emoji):
        await widget.actions.onReact(m, emoji);
      case MenuReply():
        widget.actions.onReply(m);
      case MenuCopy():
        widget.actions.onCopy(m);
    }
  }

  Future<void> _tick() async {
    try {
      await HapticFeedback.selectionClick();
    } catch (_) {}
  }

  void _dragUpdate(DragUpdateDetails d) {
    _back.stop();
    final next = (_drag + d.delta.dx).clamp(0.0, 90.0);
    final armed = next >= BubbleInteractions.replyThreshold;
    if (armed && !_armed) unawaited(_tick());
    setState(() {
      _drag = next;
      _armed = armed;
    });
  }

  void _dragEnd([DragEndDetails? _]) {
    final reply = _armed;
    _armed = false;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _drag = 0);
    } else {
      _from = _drag;
      _back.forward(from: 0);
    }
    if (reply) widget.actions.onReply(m);
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    // Your own bubbles sit against the right edge, so they follow less.
    final reach = widget.alignEnd
        ? BubbleInteractions.maxShift / 2
        : BubbleInteractions.maxShift;
    final shift =
        reach * (_drag / BubbleInteractions.replyThreshold).clamp(0.0, 1.0);
    final progress = (_drag / BubbleInteractions.replyThreshold).clamp(
      0.0,
      1.0,
    );
    final semanticActions = <CustomSemanticsAction, VoidCallback>{
      const CustomSemanticsAction(label: 'Reply'): () =>
          widget.actions.onReply(m),
      CustomSemanticsAction(label: 'React with $quickReaction'): () =>
          unawaited(widget.actions.onReact(m, quickReaction)),
      const CustomSemanticsAction(label: 'Choose a reaction'): () =>
          unawaited(_openMenu()),
    };
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPress: _openMenu,
      onSecondaryTapUp: (_) => _openMenu(),
      onDoubleTap: widget.doubleTapHeart ? _toggleHeart : null,
      onHorizontalDragUpdate: _dragUpdate,
      onHorizontalDragEnd: _dragEnd,
      onHorizontalDragCancel: _dragEnd,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (_drag > 4)
            Positioned(
              left: 4,
              top: 0,
              bottom: 0,
              child: ExcludeSemantics(
                child: Center(
                  child: Opacity(
                    opacity: progress,
                    child: Transform.scale(
                      scale: .6 + .4 * progress,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _armed ? t.accent : t.surface,
                        ),
                        child: Icon(
                          Icons.reply_rounded,
                          size: 18,
                          color: _armed ? t.onLime : t.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(shift, 0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                widget.builder(context, _bubbleKey, semanticActions),
                if (_pops > 0 && !MediaQuery.disableAnimationsOf(context))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(child: _HeartPop(key: ValueKey(_pops))),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The small pop on a double tap: a heart grows past its size and fades.
class _HeartPop extends StatelessWidget {
  const _HeartPop({super.key});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 560),
    builder: (context, v, _) {
      final scale = v < .35
          ? Curves.easeOutBack.transform(v / .35) * 1.15
          : 1.15 - .15 * ((v - .35) / .65);
      final opacity = v < .6 ? 1.0 : 1 - (v - .6) / .4;
      return Opacity(
        opacity: opacity.clamp(0, 1),
        child: Transform.scale(
          scale: scale,
          child: const Icon(
            Icons.favorite_rounded,
            key: Key('heart-pop'),
            size: 44,
            color: Color(0xffff5c7a),
          ),
        ),
      );
    },
  );
}

// ------------------------------------------------------------------- menu

/// What the floating menu returns.
sealed class MenuChoice {
  const MenuChoice();
}

/// A reaction was picked; null clears this account's (the picked one was set).
class MenuReact extends MenuChoice {
  final String? emoji;
  const MenuReact(this.emoji);
}

class MenuReply extends MenuChoice {
  const MenuReply();
}

class MenuCopy extends MenuChoice {
  const MenuCopy();
}

/// The compact menu over a message: the six quick reactions in a pill, and
/// Reply and Copy below. Everything except the message dims, so the pill reads
/// as belonging to it. Returns the choice, or null if it was dismissed.
Future<MenuChoice?> showReactionMenu(
  BuildContext context, {
  required Rect anchor,
  required String? mine,
  required bool canCopy,
  bool alignEnd = false,
}) {
  final still = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<MenuChoice>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: 'Close message options',
    barrierColor: Colors.transparent,
    transitionDuration: still
        ? Duration.zero
        : const Duration(milliseconds: 170),
    pageBuilder: (context, _, _) => ReactionMenuScene(
      anchor: anchor,
      mine: mine,
      canCopy: canCopy,
      alignEnd: alignEnd,
    ),
    transitionBuilder: (context, animation, _, child) {
      if (still) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: .94, end: 1).animate(curved),
          alignment: Alignment(
            alignEnd ? .8 : -.8,
            anchor.top > 300 ? .4 : -.4,
          ),
          child: child,
        ),
      );
    },
  );
}

/// The full-screen layer of the menu: a dim with the message left bright, the
/// pill and the action card. Exposed for tests and previews.
class ReactionMenuScene extends StatelessWidget {
  final Rect anchor;
  final String? mine;
  final bool canCopy, alignEnd;
  const ReactionMenuScene({
    super.key,
    required this.anchor,
    required this.mine,
    required this.canCopy,
    this.alignEnd = false,
  });

  static const pillHeight = 56.0, gap = 8.0, edge = 8.0, tileHeight = 52.0;
  static const actionsWidth = 208.0;

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final media = MediaQuery.of(context);
    final size = media.size;
    final top = media.padding.top + edge;
    final bottom =
        size.height - media.padding.bottom - media.viewInsets.bottom - edge;
    // Six 48 dp targets, 4 dp of padding each side and the 1 dp edge: 298 dp,
    // which fits a 320 dp window with its 8 dp margins.
    final pillWidth = math.min(
      6 * ChatMetrics.hit + 8.0 + 2.0,
      size.width - 2 * edge,
    );
    // Tiles, 4 dp of padding above and below, and the 1 dp edge.
    final actionsHeight = tileHeight * (canCopy ? 2 : 1) + 10;

    double clampX(double x, double width) =>
        x.clamp(edge, math.max(edge, size.width - edge - width)).toDouble();
    double alignedX(double width) =>
        clampX(alignEnd ? anchor.right - width : anchor.left, width);

    // The pill above the message when there is room, else below it; the
    // actions on the other side. A message too tall for either keeps the pill
    // at the top and the actions at the bottom of the screen.
    double pillTop, actionsTop;
    final above = anchor.top - gap - pillHeight;
    final below = anchor.bottom + gap;
    if (above >= top && below + actionsHeight <= bottom) {
      pillTop = above;
      actionsTop = below;
    } else if (above >= top + actionsHeight + gap) {
      pillTop = above;
      actionsTop = above - gap - actionsHeight;
      // Both above: pill nearest the message, actions over it.
    } else if (below + pillHeight + gap + actionsHeight <= bottom) {
      pillTop = below;
      actionsTop = below + pillHeight + gap;
    } else {
      pillTop = top;
      actionsTop = bottom - actionsHeight;
    }
    if (pillTop < top) pillTop = top;

    final hole = RRect.fromRectAndRadius(
      anchor.inflate(2),
      const Radius.circular(24),
    );
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Message options',
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('reaction-menu-dismiss'),
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                child: ExcludeSemantics(
                  child: CustomPaint(
                    painter: _DimPainter(
                      hole,
                      Colors.black.withValues(alpha: t.isDark ? .55 : .35),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: alignedX(pillWidth),
              top: pillTop,
              width: pillWidth,
              height: pillHeight,
              child: _Pill(mine: mine, tokens: t),
            ),
            Positioned(
              left: alignedX(actionsWidth),
              top: actionsTop,
              width: actionsWidth,
              height: actionsHeight,
              child: _Actions(canCopy: canCopy, tokens: t),
            ),
          ],
        ),
      ),
    );
  }
}

class _DimPainter extends CustomPainter {
  final RRect hole;
  final Color color;
  const _DimPainter(this.hole, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(hole);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.hole != hole || old.color != color;
}

class _Pill extends StatelessWidget {
  final String? mine;
  final ChatTokens tokens;
  const _Pill({required this.mine, required this.tokens});
  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Container(
      key: const Key('reaction-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: t.elevated,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: t.hairline.withValues(alpha: t.isDark ? .8 : 1),
        ),
        boxShadow: [
          BoxShadow(
            color: t.shadow.withValues(alpha: t.isDark ? .5 : .16),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final emoji in reactionEmojis)
            _PillEmoji(
              emoji: emoji,
              selected: emoji == mine,
              tokens: t,
              // Picking the one already set clears it.
              onTap: () => Navigator.pop(
                context,
                MenuReact(emoji == mine ? null : emoji),
              ),
            ),
        ],
      ),
    );
  }
}

class _PillEmoji extends StatelessWidget {
  final String emoji;
  final bool selected;
  final ChatTokens tokens;
  final VoidCallback onTap;
  const _PillEmoji({
    required this.emoji,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: selected ? 'Remove $emoji reaction' : 'React with $emoji',
    excludeSemantics: true,
    onTap: onTap,
    child: PressScale(
      key: Key('react-$emoji'),
      onTap: onTap,
      pressedScale: 1.18,
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        width: ChatMetrics.hit,
        height: ChatMetrics.hit,
        child: Center(
          child: Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? tokens.accent.withValues(alpha: tokens.isDark ? .25 : .16)
                  : null,
              border: selected
                  ? Border.all(color: tokens.accent, width: 1.5)
                  : null,
            ),
            child: Text(
              emoji,
              textScaler: TextScaler.noScaling,
              style: const TextStyle(
                fontSize: 26,
                height: 1.15,
                fontFamilyFallback: emojiFonts,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Actions extends StatelessWidget {
  final bool canCopy;
  final ChatTokens tokens;
  const _Actions({required this.canCopy, required this.tokens});
  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Container(
      key: const Key('reaction-actions'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: t.elevated,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: t.hairline.withValues(alpha: t.isDark ? .8 : 1),
        ),
        boxShadow: [
          BoxShadow(
            color: t.shadow.withValues(alpha: t.isDark ? .5 : .16),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          _ActionTile(
            key: const Key('menu-reply'),
            icon: Icons.reply_rounded,
            label: 'Reply',
            tokens: t,
            onTap: () => Navigator.pop(context, const MenuReply()),
          ),
          if (canCopy)
            _ActionTile(
              key: const Key('menu-copy'),
              icon: Icons.content_copy_rounded,
              label: 'Copy',
              tokens: t,
              onTap: () => Navigator.pop(context, const MenuCopy()),
            ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final ChatTokens tokens;
  final VoidCallback onTap;
  const _ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.tokens,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: PressScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      pressedScale: .97,
      child: SizedBox(
        height: ReactionMenuScene.tileHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: clampedChrome(
            context,
            Row(
              children: [
                Icon(icon, size: 21, color: tokens.text),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: tokens.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
