import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/feed_state.dart';
import '../../core/theme.dart';
import '../../core/user_error.dart';
import '../../shared/person_link.dart';
import '../../shared/press_scale.dart';
import 'comments_sheet.dart';
import 'post_action_pill.dart';
import 'post_media_carousel.dart';
import 'post_menu.dart';
import 'pulse_common.dart';

/// One post in Pulse. Changes go through the feed it belongs to.
class PostCard extends ConsumerWidget {
  final Post post;
  final String mode;
  const PostCard({super.key, required this.post, this.mode = 'following'});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final feed = ref.read(feedProvider(mode).notifier);
    Future<void> guarded(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        if (context.mounted) showFailure(context, e);
      }
    }

    void react(String? reaction) =>
        guarded(() => feed.react(post.postId, reaction));

    // A short line with no photo is the whole post, so it gets to be big.
    final statement = post.media.isEmpty && post.body.length <= 90;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        key: Key('post-${post.postId}'),
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(VibeRadius.surface),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PostHeader(post: post, mode: mode),
            if (post.body.isNotEmpty)
              _PostBody(body: post.body, statement: statement),
            if (post.media.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(VibeRadius.surface - 6),
                  child: PostMediaCarousel(
                    media: post.media,
                    onDoubleTap: () {
                      if (post.myReaction == null) react('heart');
                    },
                  ),
                ),
              ),
            // The count pills stay on one line however large the text is set.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: _PostActionBar(
                post: post,
                mode: mode,
                onReact: react,
                onToggleSave: () => guarded(() => feed.toggleSave(post.postId)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostHeader extends ConsumerWidget {
  final Post post;
  final String mode;
  const _PostHeader({required this.post, required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 2, 8),
      child: Row(
        children: [
          PressScale(
            borderRadius: BorderRadius.circular(100),
            semanticLabel: post.mine
                ? 'Open your profile'
                : 'Open ${post.author.name}’s profile',
            onTap: () => post.mine
                ? context.go('/profile')
                : openPerson(context, post.author.userId),
            child: PulseAvatar.of(post.author, radius: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.author.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15.5,
                  ),
                ),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '@${post.author.username} · ${shortAgo(post.createdAt)} · ',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(
                      audienceIcon(post.audience),
                      size: 13,
                      semanticLabel: audienceLabels[post.audience],
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Tooltip(
            message: 'Post options',
            child: PressScale(
              key: Key('post-menu-${post.postId}'),
              minHeight: 48,
              semanticLabel: 'Post options',
              onTap: () => showPostMenu(context, ref, post, mode),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                  Icons.more_horiz_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PostBody extends StatelessWidget {
  final String body;
  final bool statement;
  const _PostBody({required this.body, required this.statement});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      18,
      statement ? 4 : 0,
      18,
      statement ? 14 : 12,
    ),
    child: Text(
      body,
      style: statement
          ? const TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 22,
              height: 1.3,
              letterSpacing: -.4,
              fontWeight: FontWeight.w600,
            )
          : const TextStyle(fontSize: 15.5, height: 1.5),
    ),
  );
}

class _PostActionBar extends ConsumerWidget {
  final Post post;
  final String mode;
  final void Function(String?) onReact;
  final VoidCallback onToggleSave;
  const _PostActionBar({
    required this.post,
    required this.mode,
    required this.onReact,
    required this.onToggleSave,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 2, 6),
      child: Row(
        children: [
          PostReactButton(post: post, onReact: onReact),
          const SizedBox(width: 8),
          PostActionPill(
            key: Key('comments-${post.postId}'),
            semanticLabel: post.commentCount == 0
                ? 'Comment'
                : '${post.commentCount} comments',
            onTap: () => showComments(context, ref, post, mode),
            icon: const Icon(Icons.mode_comment_outlined, size: 20),
            label: post.commentCount == 0 ? '' : '${post.commentCount}',
          ),
          const Spacer(),
          Tooltip(
            message: post.saved ? 'Remove from saved' : 'Save',
            child: PressScale(
              key: Key('save-${post.postId}'),
              minHeight: 48,
              semanticLabel: post.saved ? 'Remove from saved' : 'Save',
              onTap: onToggleSave,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                  post.saved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  color: post.saved ? scheme.primary : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
