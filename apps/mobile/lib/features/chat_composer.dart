import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import 'chat_parts.dart';

/// The message dock: one elevated surface holding the attach button on the
/// left, a growing text field (six lines, then it scrolls) in the middle and
/// the send button on the right, which wakes up to lime when there is text.
/// Three controls, one shape; nothing decorative.
class ChatComposer extends StatefulWidget {
  /// How far the send button dips while it is pressed.
  static const sendPressScale = .88;

  final TextEditingController controller;
  final FocusNode focus;
  final bool sending, canSend, canAttach, showAttach;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend, onAttach;
  const ChatComposer({
    super.key,
    required this.controller,
    required this.focus,
    required this.sending,
    required this.canSend,
    required this.canAttach,
    required this.showAttach,
    required this.onChanged,
    required this.onSend,
    required this.onAttach,
  });
  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  bool _focused = false;

  void _focusChanged() {
    if (mounted && _focused != widget.focus.hasFocus) {
      setState(() => _focused = widget.focus.hasFocus);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(ChatComposer old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      old.focus.removeListener(_focusChanged);
      widget.focus.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    widget.focus.removeListener(_focusChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final motion = VibeMotion.duration(context);
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: conversationMaxWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: AnimatedContainer(
              key: const Key('chat-composer-dock'),
              duration: motion,
              // The 1.5 px edge is part of the 56 px.
              constraints: const BoxConstraints(
                minHeight: ChatMetrics.composerMinHeight - 3,
              ),
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                color: t.elevated,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: _focused
                      ? t.focusRing
                      : t.hairline.withValues(alpha: t.isDark ? .5 : 1),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: t.shadow.withValues(alpha: t.isDark ? .28 : .08),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.showAttach)
                    ChatIconButton(
                      key: const Key('chat-attach'),
                      icon: Icons.add_photo_alternate_outlined,
                      tooltip: 'Attach photo',
                      onTap: widget.canAttach ? widget.onAttach : null,
                      color: t.textSecondary,
                    )
                  else
                    const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('chat-input'),
                      controller: widget.controller,
                      focusNode: widget.focus,
                      minLines: 1,
                      maxLines: 6,
                      maxLength: 4000,
                      textInputAction: TextInputAction.send,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: widget.onChanged,
                      onSubmitted: (_) => widget.onSend(),
                      cursorColor: t.accent,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.3,
                        color: t.text,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Message…',
                        hintStyle: TextStyle(
                          color: t.textSecondary,
                          fontSize: 16,
                        ),
                        counterText: '',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 13.5,
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: widget.controller,
                    builder: (context, value, _) {
                      final ready =
                          value.text.trim().isNotEmpty && widget.canSend;
                      return Tooltip(
                        message: 'Send',
                        child: PressScale(
                          key: const Key('chat-send'),
                          onTap: ready ? widget.onSend : null,
                          semanticLabel: 'Send',
                          // A small, quick dip under the thumb; the send itself
                          // never waits for it.
                          pressedScale: ChatComposer.sendPressScale,
                          borderRadius: BorderRadius.circular(24),
                          child: SizedBox(
                            width: ChatMetrics.hit,
                            height: ChatMetrics.hit,
                            child: Center(
                              child: AnimatedContainer(
                                duration: motion,
                                curve: Curves.easeOutCubic,
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: ready ? t.lime : t.surface,
                                ),
                                child: AnimatedScale(
                                  duration: motion,
                                  curve: Curves.easeOutCubic,
                                  scale: ready ? 1 : .88,
                                  child: widget.sending
                                      ? const Center(
                                          child: SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: VibeColors.ink,
                                            ),
                                          ),
                                        )
                                      : Icon(
                                          Icons.arrow_upward_rounded,
                                          size: 22,
                                          color: ready
                                              ? t.onLime
                                              : t.textTertiary,
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
