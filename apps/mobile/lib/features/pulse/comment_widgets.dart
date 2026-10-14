import 'package:flutter/material.dart';

import '../../core/api.dart';
import 'pulse_common.dart';

/// The scrolling list of a post's comments, with "Show more" at the end.
class CommentList extends StatelessWidget {
  final List<PostComment> items;
  final bool hasMore, loadingMore;
  final VoidCallback onShowMore;
  final void Function(PostComment) onOptions;
  const CommentList({
    super.key,
    required this.items,
    required this.hasMore,
    required this.loadingMore,
    required this.onShowMore,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final byId = {for (final c in items) c.commentId: c};
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: items.length + (hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == items.length) {
          return TextButton(
            onPressed: loadingMore ? null : onShowMore,
            child: const Text('Show more'),
          );
        }
        final c = items[i];
        final parent = c.parentId == null ? null : byId[c.parentId];
        return CommentTile(
          comment: c,
          replyingTo: parent,
          onOptions: () => onOptions(c),
        );
      },
    );
  }
}

class CommentTile extends StatelessWidget {
  final PostComment comment;

  /// The comment this one answers, when it is on screen.
  final PostComment? replyingTo;
  final VoidCallback onOptions;
  const CommentTile({
    super.key,
    required this.comment,
    required this.replyingTo,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = comment;
    return ListTile(
      key: Key('comment-${c.commentId}'),
      contentPadding: EdgeInsetsDirectional.only(
        start: c.parentId == null ? 4 : 40,
        end: 4,
      ),
      leading: PulseAvatar.of(c.author, radius: 16),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: c.author.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            TextSpan(
              text: '  ${shortAgo(c.createdAt)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      subtitle: Text(
        c.parentId != null && replyingTo != null
            ? '@${replyingTo!.author.username} ${c.body}'
            : c.body,
        style: TextStyle(color: scheme.onSurface, height: 1.4),
      ),
      onLongPress: onOptions,
      trailing: IconButton(
        tooltip: 'Comment options',
        icon: const Icon(Icons.more_vert_rounded, size: 18),
        onPressed: onOptions,
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
  const CommentInput({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
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
