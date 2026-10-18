import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../core/chat/chat_engine.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart' show showMessage;
import 'chat_parts.dart';

// Chat list actions: swipe a row for pin, mute and delete, an edit mode with bulk select, and the Deleted chats
// screen. The server keeps only per-member flags for these (pinned_at, hidden_at); see
// docs/api/26-chat-voice-video-and-list.md.

/// One button revealed behind a row.
class SwipeAction {
  final Key key;
  final String label;
  final IconData icon;
  final Color color, onColor;
  final VoidCallback onTap;
  const SwipeAction({
    required this.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onColor,
    required this.onTap,
  });
}

/// Width of one revealed action button.
const swipeActionWidth = 76.0;

/// Only one row is open at a time: opening another closes it.
final ValueNotifier<Object?> _openSwipe = ValueNotifier<Object?>(null);

/// Wraps a list row so it slides to reveal [leading] actions (swiping towards the end of the line) or
/// [trailing] actions (towards the start). It follows the reading direction, so in right-to-left languages the
/// sides swap. Every action is also a custom accessibility action, for people who do not swipe. With
/// [enabled] false (edit mode) the row does not move.
class SwipeActionRow extends StatefulWidget {
  final Widget child;
  final List<SwipeAction> leading, trailing;
  final bool enabled;
  const SwipeActionRow({
    super.key,
    required this.child,
    this.leading = const [],
    this.trailing = const [],
    this.enabled = true,
  });

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with SingleTickerProviderStateMixin {
  /// Signed distance the row is moved along the reading direction: positive reveals [leading] on the start side.
  double _offset = 0;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<double>? _anim;

  double get _maxLeading => widget.leading.length * swipeActionWidth;
  double get _maxTrailing => widget.trailing.length * swipeActionWidth;

  @override
  void initState() {
    super.initState();
    _openSwipe.addListener(_otherOpened);
  }

  @override
  void dispose() {
    _openSwipe.removeListener(_otherOpened);
    _settle.dispose();
    super.dispose();
  }

  void _otherOpened() {
    if (_openSwipe.value != this && _offset != 0) _animateTo(0);
  }

  void _animateTo(double target) {
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _offset = target);
      return;
    }
    _anim?.removeListener(_tick);
    final from = _offset;
    _anim = Tween<double>(begin: from, end: target).animate(
      CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic),
    )..addListener(_tick);
    _settle.forward(from: 0);
  }

  void _tick() => setState(() => _offset = _anim!.value);

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  void _update(DragUpdateDetails d) {
    _settle.stop();
    // Dragging right moves the row right: in LTR that reveals the start (leading) side.
    final delta = _rtl ? -d.delta.dx : d.delta.dx;
    final next = (_offset + delta).clamp(-_maxTrailing, _maxLeading).toDouble();
    if (next != 0) _openSwipe.value = this;
    setState(() => _offset = next);
  }

  void _end(DragEndDetails d) {
    final velocity = (_rtl ? -d.primaryVelocity! : d.primaryVelocity!);
    double target = 0;
    if (_offset > 0 && _maxLeading > 0) {
      if (_offset > _maxLeading / 2 || velocity > 700) target = _maxLeading;
    } else if (_offset < 0 && _maxTrailing > 0) {
      if (-_offset > _maxTrailing / 2 || velocity < -700) {
        target = -_maxTrailing;
      }
    }
    if (target == 0 && _openSwipe.value == this) _openSwipe.value = null;
    _animateTo(target);
  }

  void _close() {
    if (_openSwipe.value == this) _openSwipe.value = null;
    _animateTo(0);
  }

  Widget _panel(List<SwipeAction> actions, {required bool leading}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in actions)
          SizedBox(
            width: swipeActionWidth,
            child: Semantics(
              button: true,
              label: a.label,
              excludeSemantics: true,
              onTap: () {
                _close();
                a.onTap();
              },
              child: GestureDetector(
                key: a.key,
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _close();
                  a.onTap();
                },
                child: Container(
                  color: a.color,
                  alignment: Alignment.center,
                  child: clampedChrome(
                    context,
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(a.icon, color: a.onColor, size: 22),
                        const SizedBox(height: 4),
                        Text(
                          a.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: a.onColor,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled ||
        (widget.leading.isEmpty && widget.trailing.isEmpty)) {
      return widget.child;
    }
    final rtl = _rtl;
    final custom = <CustomSemanticsAction, VoidCallback>{
      for (final a in [...widget.leading, ...widget.trailing])
        CustomSemanticsAction(label: a.label): a.onTap,
    };
    final shift = rtl ? -_offset : _offset;
    return Semantics(
      customSemanticsActions: custom,
      child: ClipRect(
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onHorizontalDragUpdate: _update,
          onHorizontalDragEnd: _end,
          child: Stack(
            children: [
              if (_offset > 0 && widget.leading.isNotEmpty)
                Positioned.directional(
                  textDirection: Directionality.of(context),
                  start: 0,
                  top: 0,
                  bottom: 0,
                  width: math.max(_offset, 0),
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: AlignmentDirectional.centerStart,
                      minWidth: _maxLeading,
                      maxWidth: _maxLeading,
                      child: _panel(widget.leading, leading: true),
                    ),
                  ),
                ),
              if (_offset < 0 && widget.trailing.isNotEmpty)
                Positioned.directional(
                  textDirection: Directionality.of(context),
                  end: 0,
                  top: 0,
                  bottom: 0,
                  width: math.max(-_offset, 0),
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: AlignmentDirectional.centerEnd,
                      minWidth: _maxTrailing,
                      maxWidth: _maxTrailing,
                      child: _panel(widget.trailing, leading: false),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(shift, 0),
                child: _offset == 0
                    ? widget.child
                    : GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _close,
                        child: AbsorbPointer(child: widget.child),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- edit bar

/// The bar at the bottom of the list in edit mode: how many are selected and what can be done to them.
class ChatEditBar extends StatelessWidget {
  final int selected, total;
  final bool allPinned, allMuted;
  final VoidCallback onPin, onMute, onDelete, onSelectAll;
  const ChatEditBar({
    super.key,
    required this.selected,
    required this.total,
    required this.allPinned,
    required this.allMuted,
    required this.onPin,
    required this.onMute,
    required this.onDelete,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final none = selected == 0;
    Widget button(
      String key,
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool danger = false,
    }) {
      final color = none
          ? t.textTertiary
          : danger
          ? t.error
          : t.text;
      return Expanded(
        child: PressScale(
          key: Key(key),
          onTap: none ? null : onTap,
          semanticLabel: label,
          borderRadius: BorderRadius.circular(16),
          minHeight: ChatMetrics.hit,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: clampedChrome(
              context,
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: t.elevated,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        none ? 'Select chats' : '$selected selected',
                        key: const Key('edit-count'),
                        style: TextStyle(
                          color: t.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('edit-select-all'),
                    onPressed: onSelectAll,
                    child: Text(
                      selected == total ? 'Select none' : 'Select all',
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  button(
                    'edit-pin',
                    allPinned ? Icons.push_pin : Icons.push_pin_outlined,
                    allPinned ? 'Unpin' : 'Pin',
                    onPin,
                  ),
                  button(
                    'edit-mute',
                    allMuted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    allMuted ? 'Unmute' : 'Mute',
                    onMute,
                  ),
                  button(
                    'edit-delete',
                    Icons.delete_outline_rounded,
                    'Delete',
                    onDelete,
                    danger: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------- deleted chats

/// How long is left to restore a deleted chat, in words.
String restoreLeftText(DateTime until, DateTime now) {
  final left = until.difference(now);
  if (left.inDays >= 2) return 'Restorable for ${left.inDays} more days';
  if (left.inHours >= 24) return 'Restorable for 1 more day';
  if (left.inHours >= 1) {
    return 'Restorable for ${left.inHours} more ${left.inHours == 1 ? 'hour' : 'hours'}';
  }
  return 'Restorable for less than an hour';
}

/// The chats this account deleted from its list, restorable for 30 days. After that this phone's copy of a
/// chat is removed (the engine wipes it as it reads this list) and the chat is closed for this account on the
/// server. Nothing here tells the other person anything.
class DeletedChatsScreen extends StatefulWidget {
  final ChatEngine engine;
  final DateTime Function() clock;

  /// Called after a chat was restored, so the list behind refreshes.
  final VoidCallback? onRestored;
  const DeletedChatsScreen({
    super.key,
    required this.engine,
    this.clock = DateTime.now,
    this.onRestored,
  });

  @override
  State<DeletedChatsScreen> createState() => _DeletedChatsScreenState();
}

class _DeletedChatsScreenState extends State<DeletedChatsScreen> {
  List<ChatConversation>? items;
  Object? error;
  final restoring = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final next = await widget.engine.hiddenConversations();
      if (mounted) {
        setState(() {
          items = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> restore(ChatConversation c) async {
    setState(() => restoring.add(c.id));
    try {
      await widget.engine.restoreConversation(c.id);
      widget.onRestored?.call();
      await load();
      if (mounted) showMessage(context, '${c.peerName} is back in your chats.');
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          'Couldn’t restore that chat. It may be too old to restore.',
        );
        await load();
      }
    } finally {
      if (mounted) setState(() => restoring.remove(c.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final now = widget.clock();
    final list = items;
    return Scaffold(
      appBar: AppBar(title: const Text('Deleted chats')),
      body: ListView(
        key: const Key('deleted-chats'),
        padding: const EdgeInsets.fromLTRB(
          ChatMetrics.pagePadding,
          8,
          ChatMetrics.pagePadding,
          32,
        ),
        children: [
          Text(
            'A deleted chat stays here for 30 days, so you can bring it back. After that it is removed from this phone for good. The other person is never told.',
            style: TextStyle(color: t.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 16),
          if (error != null)
            Text(
              'Couldn’t load your deleted chats.',
              key: const Key('deleted-error'),
              style: TextStyle(color: t.error),
            )
          else if (list == null)
            const LinearProgressIndicator()
          else if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  'No deleted chats',
                  key: const Key('deleted-empty'),
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else
            for (final c in list)
              Padding(
                key: ValueKey(c.id),
                padding: const EdgeInsets.only(bottom: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.peerName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: t.text,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                c.restoreUntil == null
                                    ? 'Deleted'
                                    : restoreLeftText(c.restoreUntil!, now),
                                key: Key('deleted-left-${c.id}'),
                                style: TextStyle(
                                  color: t.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          key: Key('restore-${c.id}'),
                          onPressed: restoring.contains(c.id)
                              ? null
                              : () => unawaited(restore(c)),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(
                              ChatMetrics.hit,
                              ChatMetrics.hit,
                            ),
                          ),
                          child: Text(
                            'Restore',
                            style: TextStyle(
                              color: t.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// The small row under the heading: Edit (or Done) and the link to Deleted chats.
class ChatListToolbar extends StatelessWidget {
  final bool editing, canEdit;
  final VoidCallback onToggleEdit, onDeleted;
  const ChatListToolbar({
    super.key,
    required this.editing,
    required this.canEdit,
    required this.onToggleEdit,
    required this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ChatMetrics.pagePadding - 8,
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(
            key: const Key('chats-edit'),
            onPressed: canEdit || editing ? onToggleEdit : null,
            style: TextButton.styleFrom(
              minimumSize: const Size(ChatMetrics.hit, ChatMetrics.hit),
              foregroundColor: t.accent,
            ),
            child: Text(editing ? 'Done' : 'Edit'),
          ),
          TextButton.icon(
            key: const Key('chats-deleted-link'),
            onPressed: onDeleted,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('Deleted chats'),
            style: TextButton.styleFrom(
              minimumSize: const Size(ChatMetrics.hit, ChatMetrics.hit),
              foregroundColor: t.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
