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
  final focus = FocusNode();
  List<PostComment>? items;
  String? next;
  Object? error;
  PostComment? replyTo;
  bool sending = false, loadingMore = false;

  /// The replies loaded for each top-level comment, the cursor for more, and which threads are open or loading.
  final replies = <String, List<PostComment>>{};
  final repliesNext = <String, String?>{};
  final open = <String>{}, loadingReplies = <String>{};

  PulseActions get actions => ref.read(pulseActionsProvider);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    // One "Show more" at a time; a double tap would fetch the page twice.
    if (more && (loadingMore || next == null)) return;
    if (more) setState(() => loadingMore = true);
    try {
      final page = await actions.topComments(
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

  /// Opens or closes the replies of a top-level comment, loading the first page the first time.
  Future<void> toggleReplies(PostComment top, {bool more = false}) async {
    if (!more && open.contains(top.commentId)) {
      setState(() => open.remove(top.commentId));
      return;
    }
    if (loadingReplies.contains(top.commentId)) return;
    setState(() => loadingReplies.add(top.commentId));
    try {
      final page = await actions.replies(
        widget.post.postId,
        top.commentId,
        more ? repliesNext[top.commentId] : null,
      );
      if (!mounted) return;
      setState(() {
        final kept = more
            ? replies[top.commentId] ?? const <PostComment>[]
            : const <PostComment>[];
        final seen = {for (final c in kept) c.commentId};
        replies[top.commentId] = [
          ...kept,
          ...page.items.where((c) => seen.add(c.commentId)),
        ];
        repliesNext[top.commentId] = page.nextCursor;
        open.add(top.commentId);
      });
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => loadingReplies.remove(top.commentId));
    }
  }

  /// The top-level comment a comment belongs to: itself, or its parent.
  String _rootOf(PostComment c) => c.parentId ?? c.commentId;

  /// Read before an await: the sheet may be closed when the server answers.
  FeedController get _feed => ref.read(feedProvider(widget.mode).notifier);

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    final feed = _feed;
    final target = replyTo;
    try {
      final comment = await actions.addComment(
        widget.post.postId,
        text,
        parentId: target?.commentId,
      );
      feed.commentCountChanged(widget.post.postId, 1);
      if (!mounted) return;
      input.clear();
      setState(() {
        if (target == null) {
          // New comments land at the end once every older page is loaded.
          if (next == null) items = [...?items, comment];
        } else {
          // One level deep: an answer to a reply joins its top-level comment's thread.
          final root = _rootOf(target);
          items = [
            for (final c in items ?? const <PostComment>[])
              c.commentId == root
                  ? c.copyWith(replyCount: c.replyCount + 1)
                  : c,
          ];
          if (open.contains(root) && repliesNext[root] == null) {
            replies[root] = [...?replies[root], comment];
          }
        }
        replyTo = null;
      });
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  void startReply(PostComment c) {
    setState(() => replyTo = c);
    focus.requestFocus();
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
        startReply(c);
      case 'delete':
        final feed = _feed;
        try {
          await actions.deleteComment(c.commentId);
          // A top-level comment takes its replies with it; the post's count follows.
          feed.commentCountChanged(
            widget.post.postId,
            -(1 + (c.parentId == null ? c.replyCount : 0)),
          );
          if (!mounted) return;
          setState(() {
            if (c.parentId == null) {
              items = [...?items?.where((x) => x.commentId != c.commentId)];
              replies.remove(c.commentId);
              open.remove(c.commentId);
            } else {
              replies[c.parentId!] = [
                ...?replies[c.parentId!]?.where(
                  (x) => x.commentId != c.commentId,
                ),
              ];
              items = [
                for (final x in items ?? const <PostComment>[])
                  x.commentId == c.parentId
                      ? x.copyWith(replyCount: x.replyCount - 1)
                      : x,
              ];
            }
            if (replyTo?.commentId == c.commentId) replyTo = null;
          });
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

  List<Widget> _tiles(List<PostComment> list) {
    final out = <Widget>[];
    for (final c in list) {
      final isOpen = open.contains(c.commentId);
      out.add(
        CommentTile(
          comment: c,
          onOptions: () => options(c),
          onReply: () => startReply(c),
          repliesOpen: isOpen,
          loadingReplies: loadingReplies.contains(c.commentId),
          onToggleReplies: () => toggleReplies(c),
        ),
      );
      if (isOpen) {
        for (final r in replies[c.commentId] ?? const <PostComment>[]) {
          out.add(
            CommentTile(
              comment: r,
              isReply: true,
              onOptions: () => options(r),
              onReply: () => startReply(r),
            ),
          );
        }
        if (repliesNext[c.commentId] != null) {
          out.add(
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 52),
                child: TextButton(
                  key: Key('more-replies-${c.commentId}'),
                  onPressed: loadingReplies.contains(c.commentId)
                      ? null
                      : () => toggleReplies(c, more: true),
                  child: const Text('Show more replies'),
                ),
              ),
            ),
          );
        }
      }
    }
    return out;
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
                : ListView(
                    children: [
                      ..._tiles(list),
                      if (next != null)
                        TextButton(
                          key: const Key('comments-more'),
                          onPressed: loadingMore
                              ? null
                              : () => load(more: true),
                          child: const Text('Show more'),
                        ),
                    ],
                  ),
          ),
          if (replyTo != null)
            ReplyBanner(
              name: replyTo!.author.name,
              onCancel: () => setState(() => replyTo = null),
            ),
          CommentInput(
            controller: input,
            focusNode: focus,
            sending: sending,
            onSend: send,
          ),
        ],
      ),
    );
  }
}
