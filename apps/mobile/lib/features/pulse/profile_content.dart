import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/state.dart';
import '../../shared/widgets.dart';
import 'pulse_common.dart';

/// One person's first page of posts, for their profile.
final profilePostsProvider = FutureProvider.autoDispose
    .family<List<Post>, String>(
      (ref, userId) async =>
          (await ref.watch(apiProvider).userPosts(requireSession(ref), userId))
              .items,
      retry: apiReadRetry,
    );

/// The Posts (0) or Media (1) tab of a profile, or null while there's nothing
/// to show so the profile keeps its own empty state.
Widget? profileContent(WidgetRef ref, String userId, int tab) {
  final posts = ref.watch(profilePostsProvider(userId)).asData?.value;
  if (posts == null || posts.isEmpty) return null;
  if (tab == 0) return _ProfilePostList(posts: posts);
  final photos = [for (final p in posts) ...p.media];
  if (photos.isEmpty) return null;
  return _PhotoGrid(photos: photos);
}

class _ProfilePostList extends StatelessWidget {
  final List<Post> posts;
  const _ProfilePostList({required this.posts});

  // The profile page owns the scrolling; this list only lays its rows out.
  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: EdgeInsets.zero,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    itemCount: posts.length,
    itemBuilder: (context, i) => _ProfilePostRow(post: posts[i]),
  );
}

class _ProfilePostRow extends StatelessWidget {
  final Post post;
  const _ProfilePostRow({required this.post});

  @override
  Widget build(BuildContext context) {
    final p = post;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: VibePanel(
        key: Key('profile-post-${p.postId}'),
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.media.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: PostPhoto(p.media.first),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.body.isNotEmpty)
                    Text(p.body, maxLines: 3, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  Text(
                    '${shortAgo(p.createdAt)} · ${p.reactionCount} reactions · ${p.commentCount} comments',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  final List<PostMedia> photos;
  const _PhotoGrid({required this.photos});

  void _open(BuildContext context, PostMedia m) =>
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            body: InteractiveViewer(
              child: Center(child: PostPhoto(m, fit: BoxFit.contain)),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
    ),
    itemCount: photos.length,
    itemBuilder: (context, i) => Semantics(
      button: true,
      label: 'Open photo',
      child: GestureDetector(
        onTap: () => _open(context, photos[i]),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: PostPhoto(photos[i]),
        ),
      ),
    ),
  );
}
