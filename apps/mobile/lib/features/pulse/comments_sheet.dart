import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/feed_state.dart';
import '../../core/user_error.dart';
import '../safety.dart';
import 'comment_widgets.dart';
import 'pulse_actions.dart';

Future<void> showComments(
  BuildContext context,
  WidgetRef ref,
  Post post,
  String mode,
) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: .85,
    child: _CommentsSheet(post: post, mode: mode),
  ),
);

class _CommentsSheet extends ConsumerStatefulWidget {
  final Post post;
  final String mode;
  const _CommentsSheet({required this.post, required this.mode});
  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  final input = TextEditingController();
  List<PostComment>? items;
  String? next;
  Object? error;
  PostComment? replyTo;
  bool sending = false, loadingMore = false;

  PulseActions get actions => ref.read(pulseActionsProvider);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    // One "Show more" at a time; a double tap would fetch the page twice.
    if (more && (loadingMore || next == null)) return;
    if (more) setState(() => loadingMore = true);
    try {
      final page = await actions.comments(
        widget.post.postId,
        more ? next : null,
      );
      if (!mounted) return;
      setState(() {
        final kept = more ? items ?? const <PostComment>[] : const [];
        final seen = {for (final c in kept) c.commentId};
        items = [...kept, ...page.items.where((c) => seen.add(c.commentId))];
        next = page.nextCursor;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (more && mounted) setState(() => loadingMore = false);
    }
  }

  /// Read before an await: the sheet may be closed when the server answers.
  FeedController get _feed => ref.read(feedProvider(widget.mode).notifier);

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    final feed = _feed;
    try {
      final comment = await actions.addComment(
        widget.post.postId,
        text,
        parentId: replyTo?.commentId,
      );
      feed.commentCountChanged(widget.post.postId, 1);
      if (!mounted) return;
      input.clear();
      setState(() {
        // New comments land at the end once every older page is loaded.
        if (next == null) items = [...?items, comment];
        replyTo = null;
      });
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> options(PostComment c) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (_) => CommentOptionsSheet(comment: c),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'reply':
        setState(() => replyTo = c);
      case 'delete':
        final feed = _feed;
        try {
          await actions.deleteComment(c.commentId);
          feed.commentCountChanged(widget.post.postId, -1);
          if (mounted) {
            setState(
              () =>
                  items = [...?items?.where((x) => x.commentId != c.commentId)],
            );
          }
        } catch (e) {
          if (mounted) showFailure(context, e);
        }
      case 'report':
        await showReportSheet(
          context,
          ref,
          targetType: 'comment',
          targetId: c.commentId,
          name: c.author.name,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = items;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Text('Comments', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Expanded(
            child: error != null
                ? Center(
                    child: TextButton(
                      onPressed: load,
                      child: const Text('Couldn’t load comments. Retry'),
                    ),
                  )
                : list == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? Center(
                    child: Text(
                      'Be the first to say something.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : CommentList(
                    items: list,
                    hasMore: next != null,
                    loadingMore: loadingMore,
                    onShowMore: () => load(more: true),
                    onOptions: options,
                  ),
          ),
          if (replyTo != null)
            ReplyBanner(
              name: replyTo!.author.name,
              onCancel: () => setState(() => replyTo = null),
            ),
          CommentInput(controller: input, sending: sending, onSend: send),
        ],
      ),
    );
  }
}
