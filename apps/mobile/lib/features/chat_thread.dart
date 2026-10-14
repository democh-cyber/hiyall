import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../core/chat/chat_attachment.dart';
import '../core/chat/chat_engine.dart';
import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';
import 'chat_format.dart';
import 'chat_parts.dart';
import 'chat_photo.dart';
import 'chat_reactions_ui.dart';

export 'chat_composer.dart';
export 'chat_header.dart';
export 'chat_intro.dart';
export 'chat_parts.dart';
export 'chat_reactions_ui.dart';

// ----------------------------------------------------------- thread parts

/// "Today", "Yesterday" or a date between days: a small, quiet label.
class DayChip extends StatelessWidget {
  final String label;
  const DayChip(this.label, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Center(
        child: clampedChrome(
          context,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: t.surface.withValues(alpha: t.isDark ? .8 : 1),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: t.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A system line such as "keys changed": a quiet centred chip.
class NoticeChip extends StatelessWidget {
  final String text;
  const NoticeChip(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: t.surface.withValues(alpha: t.isDark ? .8 : 1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.hairline.withValues(alpha: .5)),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: t.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The line before the first message you had not read.
class NewMessagesDivider extends StatelessWidget {
  const NewMessagesDivider({super.key});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    Widget line() => Expanded(
      child: Container(height: 1, color: t.accent.withValues(alpha: .3)),
    );
    return Semantics(
      label: 'New messages',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: ExcludeSemantics(
          child: Row(
            children: [
              line(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'New messages',
                  key: const Key('new-messages'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: t.accent,
                  ),
                ),
              ),
              line(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a sent message is, as the small mark by its time.
class StatusMark extends StatelessWidget {
  final SendStatus status;
  final bool seen;
  final Color color;
  const StatusMark({
    super.key,
    required this.status,
    required this.seen,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final (icon, tint) = switch (status) {
      SendStatus.sending => (Icons.schedule_rounded, color),
      SendStatus.failed => (Icons.error_rounded, VibeColors.error),
      SendStatus.sent =>
        seen
            ? (Icons.done_all_rounded, t.outgoingSeen)
            : (Icons.done_rounded, color),
    };
    // The mark changes once or twice in its life (clock, tick, double tick):
    // a short cross-fade says "that happened" without drawing the eye.
    return AnimatedSwitcher(
      duration: statusFade(context),
      switchInCurve: Curves.easeOut,
      layoutBuilder: (current, previous) =>
          Stack(alignment: Alignment.center, children: [...previous, ?current]),
      child: Icon(icon, key: ValueKey(icon), size: 15, color: tint),
    );
  }
}

/// How long the delivery mark takes to cross-fade; instant with reduced motion.
Duration statusFade(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 160);

String messageTimeLabel(BuildContext context, ChatMessage m) =>
    switch (m.status) {
      SendStatus.sending => 'Sending…',
      SendStatus.failed => 'Not sent',
      SendStatus.sent => TimeOfDay.fromDateTime(
        m.shownAt.toLocal(),
      ).format(context),
    };

/// What a screen reader says for one message.
String describeMessage(
  BuildContext context,
  ChatMessage m,
  String peerName, {
  required bool seen,
}) {
  final who = m.mine ? 'You' : peerName;
  final time = TimeOfDay.fromDateTime(m.shownAt.toLocal()).format(context);
  final state = switch (m.status) {
    SendStatus.sending => ', sending',
    SendStatus.failed => ', not sent',
    SendStatus.sent => m.mine ? (seen ? ', seen' : ', sent') : '',
  };
  return '$who, $time$state';
}

class _Meta extends StatelessWidget {
  final ChatMessage message;
  final bool seen, onMedia, markKey;
  const _Meta({
    required this.message,
    required this.seen,
    this.onMedia = false,
    this.markKey = false,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final m = message;
    final Color ink = onMedia
        ? Colors.white
        : m.mine
        ? t.outgoingMeta
        : t.incomingMeta;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          messageTimeLabel(context, m),
          style: TextStyle(
            fontSize: 11.5,
            height: 1.1,
            fontWeight: FontWeight.w500,
            color: m.status == SendStatus.failed && !onMedia
                ? (m.mine ? VibeColors.error : t.error)
                : ink,
          ),
        ),
        if (m.mine) ...[
          const SizedBox(width: 3),
          KeyedSubtree(
            key: markKey && seen ? const Key('seen') : null,
            child: StatusMark(
              status: m.status,
              seen: seen,
              color: onMedia ? Colors.white : ink,
            ),
          ),
        ],
      ],
    );
    if (!onMedia) return clampedChrome(context, row);
    return clampedChrome(
      context,
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(100),
        ),
        child: row,
      ),
    );
  }
}

/// One message: the bubble (or the large emoji), the avatar gutter, grouping
/// corners and the time-and-status line on the last bubble of a run.
class ChatBubble extends StatelessWidget {
  final MessageRow row;
  final ChatEngine? engine;
  final String conversationId, peerName, peerId;
  final String? peerAvatarUrl;

  /// The peer has read up to this message.
  final bool seen;

  /// This is the newest outgoing message: its mark carries the `seen` key.
  final bool newestMine;

  /// This account's id, to tell its reactions from the peer's.
  final String selfId;

  /// Reactions, reply and copy; null leaves the bubble inert.
  final BubbleActions? actions;

  /// The quote to draw at the top of the bubble, already resolved against the
  /// local history by the screen.
  final QuoteData? quote;

  /// Briefly lit after a quote was tapped and brought this message into view.
  final bool highlight;
  const ChatBubble({
    super.key,
    required this.row,
    required this.engine,
    required this.conversationId,
    required this.peerName,
    required this.peerId,
    required this.peerAvatarUrl,
    required this.seen,
    this.newestMine = false,
    this.selfId = '',
    this.actions,
    this.quote,
    this.highlight = false,
  });

  static const radius = ChatMetrics.bubbleRadius,
      tail = ChatMetrics.bubbleTail,
      gutter = 36.0;

  /// Room around the text, sized so a one-line message is a pill.
  static const textPadding = EdgeInsets.fromLTRB(15, 10, 15, 9);

  @override
  Widget build(BuildContext context) {
    final m = row.message;
    final t = ChatTokens.of(context);
    final mine = m.mine;
    final photo = m.attachment;
    final caption = photo?.caption ?? '';
    final showMeta = row.last || m.status != SendStatus.sent;
    final meta = _Meta(message: m, seen: seen, markKey: newestMine);
    final ink = mine ? t.outgoingInk : t.incomingInk;
    final emoji = !m.isPhoto && isEmojiOnly(m.text) && quote == null;
    final quoteBlock = quote == null
        ? null
        : QuoteBlock(
            who: quote!.who,
            line: quote!.line,
            image: quote!.image,
            onOutgoing: mine,
            onTap: quote!.jumpTo == null || actions == null
                ? null
                : () => actions!.onQuoteTap(quote!.jumpTo!),
          );

    Widget body;
    if (emoji) {
      final count = m.text.trim().characters.length;
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Text(
            m.text.trim(),
            key: Key('emoji-${m.messageId}'),
            style: TextStyle(
              fontSize: count == 1 ? 52 : (count == 2 ? 44 : 38),
              height: 1.15,
            ),
          ),
          if (showMeta)
            Padding(padding: const EdgeInsets.only(top: 2), child: meta),
        ],
      );
    } else {
      final radii = bubbleRadii(
        mine: mine,
        first: row.first,
        last: row.last,
        radius: radius,
        join: ChatMetrics.bubbleJoin,
        tail: tail,
      );
      Widget inner;
      if (m.isPhoto) {
        final hasCaption = caption.isNotEmpty;
        final Widget media = photo != null && engine != null
            ? PhotoBody(
                message: m,
                engine: engine!,
                conversationId: conversationId,
                peerName: peerName,
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                child: UnsupportedPhoto(mine: mine),
              );
        final overlay =
            !hasCaption && showMeta && photo != null && engine != null;
        // The bubble is as wide as the photo: a caption wraps beneath it and
        // the time sits at the end, so nothing stretches to the maximum.
        inner = SizedBox(
          width: chatPhotoWidth(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (quoteBlock != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: QuoteBlock(
                      who: quote!.who,
                      line: quote!.line,
                      image: quote!.image,
                      onOutgoing: mine,
                      fill: true,
                      onTap: quoteBlock.onTap,
                    ),
                  ),
                ),
              overlay
                  ? Stack(
                      children: [
                        media,
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: _Meta(
                            message: m,
                            seen: seen,
                            onMedia: true,
                            markKey: newestMine,
                          ),
                        ),
                      ],
                    )
                  : media,
              if (hasCaption)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 7, 8, 0),
                  child: Text(
                    caption,
                    key: Key('photo-caption-${m.messageId}'),
                    style: TextStyle(color: ink, fontSize: 15.5, height: 1.35),
                  ),
                ),
              if (showMeta && !overlay)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 3),
                  child: Align(alignment: Alignment.centerRight, child: meta),
                ),
            ],
          ),
        );
      } else {
        final text = _TextWithMeta(
          text: m.text,
          style: TextStyle(color: ink, fontSize: 15.5, height: 1.35),
          meta: showMeta ? meta : null,
          metaWidth: showMeta ? _metaWidth(context, m) : 0,
        );
        inner = quoteBlock == null
            ? text
            : LayoutBuilder(
                builder: (context, box) {
                  // The bubble is as wide as the wider of the text and the
                  // quote, and the quote fills it.
                  final textWidth = _blockWidth(
                    context,
                    m.text,
                    TextStyle(color: ink, fontSize: 15.5, height: 1.35),
                    showMeta ? _metaWidth(context, m) : 0,
                    box.maxWidth,
                  );
                  final quoteWidth = quoteNaturalWidth(
                    context,
                    quote!.who,
                    quote!.line,
                    quote!.image,
                  );
                  return SizedBox(
                    width: math.min(
                      box.maxWidth,
                      math.max(textWidth, quoteWidth),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        QuoteBlock(
                          who: quote!.who,
                          line: quote!.line,
                          image: quote!.image,
                          onOutgoing: mine,
                          fill: true,
                          onTap: quoteBlock.onTap,
                        ),
                        const SizedBox(height: 6),
                        text,
                      ],
                    ),
                  );
                },
              );
      }
      body = DecoratedBox(
        decoration: BoxDecoration(
          gradient: mine
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: t.outgoing,
                )
              : null,
          color: mine ? null : t.incoming,
          borderRadius: radii,
          border: mine ? null : Border.all(color: t.incomingBorder),
          boxShadow: t.isDark
              ? null
              : const [
                  BoxShadow(
                    color: Color(0x0f000000),
                    blurRadius: 6,
                    offset: Offset(0, 1),
                  ),
                ],
        ),
        child: Padding(
          padding: m.isPhoto ? const EdgeInsets.all(4) : textPadding,
          child: inner,
        ),
      );
    }

    final label = describeMessage(context, m, peerName, seen: seen);
    final chips = reactionChips(m, selfId);
    final interactive = actions != null && canInteract(m);

    Widget semanticFor(
      GlobalKey? bubbleKey,
      Map<CustomSemanticsAction, VoidCallback>? custom,
    ) {
      // Text reads as one thing; a photo keeps its own button semantics.
      final bubble = KeyedSubtree(key: bubbleKey, child: body);
      return m.isPhoto
          ? Semantics(
              container: true,
              label: label,
              customSemanticsActions: custom,
              child: bubble,
            )
          : Semantics(
              container: true,
              label: quote == null
                  ? '$label: ${m.text}'
                  : '$label, replying to ${quote!.who}: ${quote!.line}: ${m.text}',
              customSemanticsActions: custom,
              child: ExcludeSemantics(child: bubble),
            );
    }

    return Padding(
      padding: EdgeInsets.only(
        top: row.first ? ChatMetrics.runGap : ChatMetrics.bubbleGap,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final room = box.maxWidth - gutter;
          final maxBubble = math.min(room * .9, 520.0);
          Widget bubbleRow(Widget semantic) => Row(
            mainAxisAlignment: mine
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!mine)
                SizedBox(
                  width: gutter,
                  child: row.showAvatar
                      ? Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: PersonAvatar(
                            key: Key('peer-avatar-${m.messageId}'),
                            name: peerName,
                            avatarUrl: peerAvatarUrl,
                            userId: peerId,
                            radius: 14,
                            initialStyle: const TextStyle(
                              fontFamily: 'SpaceGrotesk',
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : null,
                ),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxBubble),
                  child: semantic,
                ),
              ),
            ],
          );
          final Widget line = interactive
              ? BubbleInteractions(
                  message: m,
                  selfId: selfId,
                  actions: actions!,
                  alignEnd: mine,
                  doubleTapHeart: !m.isPhoto,
                  builder: (context, key, custom) =>
                      bubbleRow(semanticFor(key, custom)),
                )
              : bubbleRow(semanticFor(null, null));
          final column = Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              line,
              if (chips.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(left: mine ? 0 : gutter),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxBubble),
                    child: ReactionChips(
                      chips: chips,
                      peerName: peerName,
                      alignEnd: mine,
                      onRemoveMine: interactive
                          ? (_) => unawaited(actions!.onReact(m, null))
                          : null,
                    ),
                  ),
                ),
            ],
          );
          return highlight ? _Lit(child: column) : column;
        },
      ),
    );
  }
}

/// A soft lime wash behind a message that a tapped quote has just brought into
/// view. It fades out by itself (and simply holds, then disappears, when the
/// device asks for reduced motion).
class _Lit extends StatelessWidget {
  final Widget child;
  const _Lit({required this.child});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return DecoratedBox(
      key: const Key('message-highlight'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: t.accent.withValues(alpha: t.isDark ? .16 : .13),
      ),
      child: child,
    );
  }
}

/// Brings a newly arrived message in: your own slides up a short way from the
/// composer while it fades in, theirs settles in from just below. About 200 ms,
/// nothing waits on it (the message is already in the list and the send is
/// already under way). History that is already there, a message that has
/// played, and a device that asks for reduced motion, skip it.
class BubbleEntrance extends StatefulWidget {
  final bool mine;
  final Widget child;
  final VoidCallback? onDone;

  /// False once it has played, so scrolling back to it does not replay.
  final bool animate;
  const BubbleEntrance({
    super.key,
    required this.mine,
    required this.child,
    this.onDone,
    this.animate = true,
  });

  /// How long it takes, and how far it travels from below.
  static const duration = Duration(milliseconds: 200);
  static double rise(bool mine) => mine ? 18 : 6;
  @override
  State<BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: BubbleEntrance.duration,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.animate || MediaQuery.disableAnimationsOf(context)) {
      c.value = 1;
      widget.onDone?.call();
    } else {
      c.forward().whenComplete(() => widget.onDone?.call());
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slide = CurvedAnimation(parent: c, curve: Curves.easeOutCubic);
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: Curves.easeOut.transform(c.value).clamp(0, 1),
        child: Transform.translate(
          offset: Offset(
            0,
            BubbleEntrance.rise(widget.mine) * (1 - slide.value),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Three dots in an incoming bubble while the other person is typing. With
/// reduced motion they hold still.
class TypingBubble extends StatefulWidget {
  final String peerName, peerId;
  final String? peerAvatarUrl;
  const TypingBubble({
    super.key,
    required this.peerName,
    required this.peerId,
    required this.peerAvatarUrl,
  });
  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble>
    with SingleTickerProviderStateMixin {
  /// One breath: a soft wave runs through the three dots and then they rest,
  /// so it reads as "someone is writing", not as a blinking light.
  static const cycle = Duration(milliseconds: 1600);
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: cycle,
  );
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still == _still && c.isAnimating) return;
    _still = still;
    if (still) {
      c.stop();
      c.value = 0;
    } else if (!c.isAnimating) {
      c.repeat();
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ChatTokens.of(context);
    return Semantics(
      container: true,
      label: '${widget.peerName} is typing',
      child: ExcludeSemantics(
        child: Padding(
          key: const Key('typing-bubble'),
          padding: const EdgeInsets.only(top: ChatMetrics.runGap),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: ChatBubble.gutter,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: PersonAvatar(
                    name: widget.peerName,
                    avatarUrl: widget.peerAvatarUrl,
                    userId: widget.peerId,
                    radius: 14,
                    initialStyle: const TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 17,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: p.incoming,
                  border: Border.all(color: p.incomingBorder),
                  borderRadius: bubbleRadii(
                    mine: false,
                    first: true,
                    last: true,
                    radius: ChatBubble.radius,
                    join: ChatMetrics.bubbleJoin,
                    tail: ChatBubble.tail,
                  ),
                ),
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 3; i++) ...[
                        if (i > 0) const SizedBox(width: 5),
                        _dot(p, i),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(ChatTokens p, int i) {
    final wave = _still ? 0.0 : typingWave(c.value, i);
    return Transform.translate(
      offset: Offset(0, -3 * wave),
      child: Container(
        width: 7.5,
        height: 7.5,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: p.incomingMeta.withValues(alpha: .42 + .4 * wave),
        ),
      ),
    );
  }
}

/// How lifted dot [index] (0 to 2) is, 0 to 1, at [t] (0 to 1) through one
/// breath of [_TypingBubbleState.cycle]. Each dot rises and falls over 560 ms
/// as a half sine, 150 ms after the one before it; the last 600 ms of the
/// breath is rest. Never flashes: it is zero at both ends of every dot's turn.
double typingWave(double t, int index) {
  final ms = t * _TypingBubbleState.cycle.inMilliseconds;
  final local = (ms - index * 150) / 560;
  if (local <= 0 || local >= 1) return 0;
  return math.sin(local * math.pi);
}

/// The floating "jump to the newest message" button, shown while the person
/// has scrolled away from the bottom, with the number of messages that arrived
/// meanwhile. It fades in and out (instantly with reduced motion).
class ScrollToLatestButton extends StatelessWidget {
  final bool visible;
  final int count;
  final VoidCallback onTap;
  const ScrollToLatestButton({
    super.key,
    required this.visible,
    required this.count,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final duration = VibeMotion.duration(context);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: .85, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: !visible
          ? const SizedBox.shrink(key: ValueKey('jump-hidden'))
          : Semantics(
              key: const ValueKey('jump-visible'),
              button: true,
              label: count > 0
                  ? 'Scroll to latest, $count new ${count == 1 ? 'message' : 'messages'}'
                  : 'Scroll to latest',
              excludeSemantics: true,
              onTap: onTap,
              child: GestureDetector(
                key: const Key('scroll-to-latest'),
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: t.elevated,
                          border: Border.all(
                            color: t.hairline.withValues(
                              alpha: t.isDark ? .7 : 1,
                            ),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: t.shadow.withValues(
                                alpha: t.isDark ? .35 : .12,
                              ),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 26,
                          color: t.text,
                        ),
                      ),
                      if (count > 0)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Container(
                            key: const Key('scroll-to-latest-count'),
                            constraints: const BoxConstraints(
                              minWidth: 20,
                              minHeight: 20,
                            ),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: t.badgeFill,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: t.bg, width: 1.5),
                            ),
                            child: Text(
                              badgeCount(count),
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.1,
                                fontWeight: FontWeight.w800,
                                color: t.badgeInk,
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

/// Width of the time-and-status line, so the text can leave room for it.
double _metaWidth(BuildContext context, ChatMessage m) {
  final tp = TextPainter(
    text: TextSpan(
      text: messageTimeLabel(context, m),
      // Measured in the font the line is drawn in (the theme's), not the
      // platform default, which is narrower than it.
      style: DefaultTextStyle.of(context).style
          .merge(const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    ),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
  )..layout();
  final w = tp.width + (m.mine ? 18 : 0);
  tp.dispose();
  return w;
}

/// The width [_TextWithMeta] takes for [text] in at most [maxWidth]: the text's
/// own width, widened for the time when it fits on the last line or is wider
/// than the text when it does not.
double _blockWidth(
  BuildContext context,
  String text,
  TextStyle style,
  double metaWidth,
  double maxWidth,
) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    textWidthBasis: TextWidthBasis.longestLine,
  )..layout(maxWidth: maxWidth);
  final lines = tp.computeLineMetrics();
  final lastLine = lines.isEmpty ? 0.0 : lines.last.width;
  final width = tp.width;
  tp.dispose();
  if (metaWidth == 0) return width;
  const gap = 10.0;
  return lastLine + gap + metaWidth <= maxWidth
      ? math.max(width, lastLine + gap + metaWidth)
      : math.max(width, metaWidth);
}

/// Message text with the time tucked into the end of its last line when there
/// is room, and on a line of its own when there is not. The bubble is only as
/// wide as the text needs.
class _TextWithMeta extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Widget? meta;
  final double metaWidth;
  const _TextWithMeta({
    required this.text,
    required this.style,
    required this.meta,
    required this.metaWidth,
  });
  @override
  Widget build(BuildContext context) {
    final body = Text(
      text,
      style: style,
      textWidthBasis: TextWidthBasis.longestLine,
    );
    if (meta == null) return body;
    return LayoutBuilder(
      builder: (context, box) {
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          textWidthBasis: TextWidthBasis.longestLine,
        )..layout(maxWidth: box.maxWidth);
        final lines = tp.computeLineMetrics();
        final lastLine = lines.isEmpty ? 0.0 : lines.last.width;
        final width = tp.width;
        tp.dispose();
        const gap = 10.0;
        if (lastLine + gap + metaWidth <= box.maxWidth) {
          return SizedBox(
            width: math.max(width, lastLine + gap + metaWidth),
            child: Stack(
              children: [
                body,
                Positioned(right: 0, bottom: 1, child: meta!),
              ],
            ),
          );
        }
        return SizedBox(
          width: math.max(width, metaWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              body,
              const SizedBox(height: 2),
              Align(alignment: Alignment.centerRight, child: meta),
            ],
          ),
        );
      },
    );
  }
}
