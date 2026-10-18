import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import 'chat_parts.dart';
import 'chat_voice_ui.dart';

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

  /// Shown above the dock inside the same column: the "Replying to" bar and a
  /// notice. Null or an empty box adds nothing.
  final Widget? above;

  /// Set to the peer's name while they have not replied and the first-contact
  /// cap is used up: the composer is disabled and says whom it waits for.
  final String? waitingFor;

  /// The microphone: when set, an empty composer offers a voice message (tap to record, or hold). Null leaves
  /// the composer as text and attachments only.
  final VoiceControls? voice;
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
    this.above,
    this.waitingFor,
    this.voice,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // (AnimatedSize with a zero duration trips a framework assert.)
              if (motion == Duration.zero)
                widget.above ?? const SizedBox.shrink()
              else
                AnimatedSize(
                  duration: motion,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: widget.above ?? const SizedBox(width: double.infinity),
                ),
              _dock(context, t, motion),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dock(BuildContext context, ChatTokens t, Duration motion) {
    return Padding(
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
        child: widget.voice == null
            ? _controls(context, t, motion, null)
            : ListenableBuilder(
                listenable: widget.voice!.capture,
                builder: (context, _) =>
                    _controls(context, t, motion, widget.voice),
              ),
      ),
    );
  }

  /// The row inside the dock. While a voice message is being recorded the text field and the attach button
  /// give way to the recording bar; the microphone button stays where it is (so a held finger keeps its
  /// gesture) until the recording is locked, when the bar brings its own send button.
  Widget _controls(
    BuildContext context,
    ChatTokens t,
    Duration motion,
    VoiceControls? voice,
  ) {
    final capture = voice?.capture;
    final recording = capture != null && capture.busy;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (recording)
          Expanded(
            child: RecordingBar(
              capture: capture,
              onSend: () => unawaited(voice!.onFinish()),
            ),
          )
        else ...[
          if (widget.showAttach)
            ChatIconButton(
              key: const Key('chat-attach'),
              icon: Icons.add_photo_alternate_outlined,
              tooltip: 'Attach photo or video',
              onTap: widget.canAttach && widget.waitingFor == null
                  ? widget.onAttach
                  : null,
              color: t.textSecondary,
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('chat-input'),
              enabled: widget.waitingFor == null,
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
              style: TextStyle(fontSize: 16, height: 1.3, color: t.text),
              decoration: InputDecoration(
                hintText: widget.waitingFor == null
                    ? 'Message…'
                    : 'Waiting for ${widget.waitingFor} to reply',
                hintStyle: TextStyle(color: t.textSecondary, fontSize: 16),
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
        ],
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final empty = value.text.trim().isEmpty;
            final mic =
                voice != null &&
                widget.waitingFor == null &&
                (recording ? !capture.locked : empty);
            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (mic) MicButton(key: const ValueKey('mic'), controls: voice),
                if (!recording) _sendButton(context, t, motion, value),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _sendButton(
    BuildContext context,
    ChatTokens t,
    Duration motion,
    TextEditingValue value,
  ) {
    final ready =
        value.text.trim().isNotEmpty &&
        widget.canSend &&
        widget.waitingFor == null;
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
                        color: ready ? t.onLime : t.textTertiary,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
