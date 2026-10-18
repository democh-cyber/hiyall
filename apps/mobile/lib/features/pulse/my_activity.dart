import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/pulse7.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';
import '../../shared/widgets.dart';
import 'pulse_common.dart';

/// What you wrote and what you reacted to, newest first, with the post each belongs to. Two tabs, Comments and
/// Likes (`GET /v1/me/activity/comments` and `/reactions`). A row opens its post; a post that is gone, or that you
/// can no longer see, reads "removed" and does not open.
class MyActivityScreen extends StatelessWidget {
  const MyActivityScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('My activity'),
        leading: BackButton(
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/profile'),
        ),
        bottom: const TabBar(
          tabs: [
            Tab(key: Key('activity-tab-comments'), text: 'Comments'),
            Tab(key: Key('activity-tab-likes'), text: 'Likes'),
          ],
        ),
      ),
      body: const SafeArea(
        child: ReadingWidth(
          child: TabBarView(
            children: [
              _ActivityList<MyComment>(
                keyName: 'comments',
                empty: 'You haven’t commented on anything yet.',
                fetch: _comments,
                row: _commentRow,
              ),
              _ActivityList<MyReaction>(
                keyName: 'likes',
                empty: 'You haven’t reacted to any posts yet.',
                fetch: _reactions,
                row: _reactionRow,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<ApiPage<MyComment>> _comments(WidgetRef ref, String? cursor) =>
    ref.read(pulse7Provider).myComments(pulse7SessionOf(ref), cursor);

Future<ApiPage<MyReaction>> _reactions(WidgetRef ref, String? cursor) =>
    ref.read(pulse7Provider).myReactions(pulse7SessionOf(ref), cursor);

Widget _commentRow(BuildContext context, MyComment c) => _ActivityRow(
  id: c.commentId,
  post: c.post,
  headline: c.parentId == null ? 'You commented' : 'You replied',
  detail: c.body,
  at: c.createdAt,
);

const _emoji = {
  'heart': '❤️',
  'fire': '🔥',
  'laugh': '😂',
  'wow': '😮',
  'sad': '😢',
};

Widget _reactionRow(BuildContext context, MyReaction r) => _ActivityRow(
  id: '${r.postId}-${r.reaction}',
  post: r.post,
  headline: 'You reacted ${_emoji[r.reaction] ?? ''}'.trim(),
  detail: '',
  at: r.createdAt,
);

class _ActivityList<T> extends ConsumerStatefulWidget {
  final String keyName, empty;
  final Future<ApiPage<T>> Function(WidgetRef ref, String? cursor) fetch;
  final Widget Function(BuildContext context, T item) row;
  const _ActivityList({
    required this.keyName,
    required this.empty,
    required this.fetch,
    required this.row,
  });
  @override
  ConsumerState<_ActivityList<T>> createState() => _ActivityListState<T>();
}

class _ActivityListState<T> extends ConsumerState<_ActivityList<T>>
    with AutomaticKeepAliveClientMixin {
  List<T>? items;
  String? next;
  Object? error;
  bool loadingMore = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool more = false}) async {
    if (more && (loadingMore || next == null)) return;
    if (more) setState(() => loadingMore = true);
    try {
      final page = await widget.fetch(ref, more ? next : null);
      if (!mounted) return;
      setState(() {
        items = more ? [...?items, ...page.items] : page.items;
        next = page.nextCursor;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (more && mounted) setState(() => loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final list = items;
    if (error != null && list == null) {
      return Center(
        child: FailureCard(error: error!, retry: load),
      );
    }
    if (list == null) return const Center(child: CircularProgressIndicator());
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.empty,
            key: Key('activity-empty-${widget.keyName}'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        key: Key('activity-list-${widget.keyName}'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          for (final item in list) widget.row(context, item),
          if (next != null)
            TextButton(
              key: Key('activity-more-${widget.keyName}'),
              onPressed: loadingMore ? null : () => load(more: true),
              child: Text(loadingMore ? 'Loading…' : 'Show more'),
            ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final String id, headline, detail;
  final ActivityPost post;
  final DateTime at;
  const _ActivityRow({
    required this.id,
    required this.post,
    required this.headline,
    required this.detail,
    required this.at,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final removed = post.removed;
    final summary = removed
        ? 'This post was removed'
        : post.excerpt.isNotEmpty
        ? post.excerpt
        : post.hasVoice
        ? 'Voice note'
        : post.hasMedia
        ? 'Photo post'
        : 'Post';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PressScale(
        key: Key('activity-row-$id'),
        minHeight: 48,
        semanticLabel: removed
            ? '$headline. This post was removed'
            : '$headline. Open the post',
        onTap: removed ? null : () => context.push('/post/${post.postId}'),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.elevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: t.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: headline,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    TextSpan(
                      text: '  ${shortAgo(at)}',
                      style: TextStyle(fontSize: 12, color: t.textSecondary),
                    ),
                  ],
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(detail, style: TextStyle(color: t.text, height: 1.35)),
              ],
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    if (!removed && post.author != null) ...[
                      PulseAvatar.of(post.author!, radius: 12),
                      const SizedBox(width: 8),
                    ],
                    if (removed) ...[
                      Icon(
                        Icons.visibility_off_outlined,
                        size: 18,
                        color: t.textSecondary,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        key: Key('activity-post-${post.postId}'),
                        style: TextStyle(
                          color: removed ? t.textSecondary : t.text,
                          fontStyle: removed ? FontStyle.italic : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
