import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';
import 'pulse_common.dart';
import 'translate_button.dart';

/// Whether a comment is still waiting for the server to take it (shown at once, then replaced).
bool isPendingComment(PostComment c) => c.commentId.startsWith('pending-');

/// One comment or reply, with its actions: Reply, and for a top-level comment "View N replies".
class CommentTile extends StatelessWidget {
  final PostComment comment;

  /// A reply is drawn indented under its comment.
  final bool isReply;
  final bool repliesOpen, loadingReplies;
  final VoidCallback onOptions, onReply;
  final VoidCallback? onToggleReplies;
  const CommentTile({
    super.key,
    required this.comment,
    required this.onOptions,
    required this.onReply,
    this.isReply = false,
    this.repliesOpen = false,
    this.loadingReplies = false,
    this.onToggleReplies,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final c = comment;
    final pending = isPendingComment(c);
    final n = c.replyCount;
    final toggleLabel = repliesOpen
        ? 'Hide replies'
        : n == 1
        ? 'View 1 reply'
        : 'View $n replies';
    return Opacity(
      opacity: pending ? .6 : 1,
      child: Padding(
        key: Key('comment-${c.commentId}'),
        padding: EdgeInsetsDirectional.only(
          start: isReply ? 52 : 12,
          end: 4,
          top: 6,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PulseAvatar.of(c.author, radius: isReply ? 13 : 16),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPress: pending ? null : onOptions,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: c.author.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(
                            text: pending
                                ? '  Sending…'
                                : '  ${shortAgo(c.createdAt)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: t.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    TranslateScope(
                      id: c.commentId,
                      text: c.body,
                      builder: (context, shown, button) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            shown,
                            style: TextStyle(color: t.text, height: 1.4),
                          ),
                          ?button,
                        ],
                      ),
                    ),
                    if (!pending)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _TextAction(
                            key: Key('reply-${c.commentId}'),
                            label: 'Reply',
                            onTap: onReply,
                          ),
                          if (!isReply && n > 0 && onToggleReplies != null)
                            _TextAction(
                              key: Key('replies-${c.commentId}'),
                              label: loadingReplies
                                  ? 'Loading replies…'
                                  : toggleLabel,
                              onTap: loadingReplies ? null : onToggleReplies,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            if (!pending)
              IconButton(
                key: Key('comment-options-${c.commentId}'),
                tooltip: 'Comment options',
                icon: const Icon(Icons.more_vert_rounded, size: 18),
                onPressed: onOptions,
              ),
          ],
        ),
      ),
    );
  }
}

/// A quiet text button at least 48 high, for Reply and the replies toggle.
class _TextAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _TextAction({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return PressScale(
      minHeight: 48,
      semanticLabel: label,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: t.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// "Replying to X" above the input, with a way to cancel.
class ReplyBanner extends StatelessWidget {
  final String name;
  final VoidCallback onCancel;
  const ReplyBanner({super.key, required this.name, required this.onCancel});

  @override
  Widget build(BuildContext context) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
    child: Row(
      children: [
        Expanded(child: Text('Replying to $name')),
        IconButton(
          tooltip: 'Cancel reply',
          icon: const Icon(Icons.close_rounded, size: 18),
          onPressed: onCancel,
        ),
      ],
    ),
  );
}

class CommentInput extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final FocusNode? focusNode;
  const CommentInput({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('comment-input'),
              controller: controller,
              focusNode: focusNode,
              maxLength: 1000,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Add a comment…',
                counterText: '',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          IconButton.filled(
            key: const Key('comment-send'),
            tooltip: 'Send',
            onPressed: sending ? null : onSend,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
    ),
  );
}

/// Reply, delete (when allowed) and report for one comment.
class CommentOptionsSheet extends StatelessWidget {
  final PostComment comment;
  const CommentOptionsSheet({super.key, required this.comment});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.reply_rounded),
          title: const Text('Reply'),
          onTap: () => Navigator.pop(context, 'reply'),
        ),
        if (comment.canDelete)
          ListTile(
            key: const Key('delete-comment'),
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('Delete comment'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        if (!comment.mine)
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report comment'),
            onTap: () => Navigator.pop(context, 'report'),
          ),
        const SizedBox(height: 8),
      ],
    ),
  );
}
