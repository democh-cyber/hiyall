import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../core/api.dart';
import '../core/feed_state.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/person_avatar.dart';
import '../shared/person_link.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart';
import '../shared/story_canvas.dart';
import 'people_lists.dart' show storyTimeLeft;
import 'safety.dart';
import '../core/user_error.dart';

export 'story_composer.dart' show StoryComposerScreen;

/// "now", "5m", "3h", "2d", then a date: compact enough for a card header.
String shortAgo(DateTime at, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  final l = at.toLocal();
  return '${l.day}/${l.month}/${l.year % 100}';
}

const audienceLabels = {
  'public': 'Everyone',
  'followers': 'Followers',
  'friends': 'Friends',
};

IconData audienceIcon(String audience) => switch (audience) {
  'public' => Icons.public_rounded,
  'friends' => Icons.favorite_border_rounded,
  _ => Icons.group_outlined,
};

/// The audience a new post or story starts with, from the person's privacy.
String defaultAudience(String? setting) => switch (setting) {
  'public' => 'public',
  'followers' => 'followers',
  _ => 'friends',
};

Future<void> showCreateSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Start a circle'),
                subtitle: const Text('Community, Moment or event'),
                onTap: () {
                  Navigator.pop(sheet);
                  context.push('/spaces');
                },
              ),
              ListTile(
                key: const Key('create-post'),
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('New post'),
                subtitle: const Text('Words, photos or both'),
                onTap: () {
                  Navigator.pop(sheet);
                  context.push('/compose');
                },
              ),
              ListTile(
                key: const Key('create-story'),
                leading: const Icon(Icons.auto_awesome_motion_outlined),
                title: const Text('Add to your story'),
                subtitle: const Text('Gone in 24 hours or less'),
                onTap: () {
                  Navigator.pop(sheet);
                  context.push('/story/new');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

/// A post, comment or story author's avatar.
class _Avatar extends StatelessWidget {
  final String name, userId;
  final String? avatarUrl;
  final double radius;
  const _Avatar(
    this.name, {
    this.radius = 20,
    this.userId = '',
    this.avatarUrl,
  });
  _Avatar.of(Person person, {double radius = 20})
    : this(
        person.name,
        radius: radius,
        userId: person.userId,
        avatarUrl: person.avatarUrl,
      );
  @override
  Widget build(BuildContext context) => PersonAvatar(
    name: name,
    avatarUrl: avatarUrl,
    userId: userId,
    radius: radius,
  );
}

/// Builds the pixels for a post photo. Replaced in tests, which must not
/// reach the network or the on-disk image cache.
@visibleForTesting
ImageProvider Function(String url, String cacheKey) postPhotoFactory = (
  url,
  cacheKey,
) => CachedNetworkImageProvider(url, cacheKey: cacheKey);

/// Pixels worth decoding for a photo shown [logical] pixels wide on a screen
/// of density [dpr]: rounded up to a multiple of 64 so a layout that shifts a
/// little reuses the same decoded image, and never more than [cap] (the
/// server's longest edge). A 2048 px upload shown 360 px wide on a 3x phone
/// decodes at 1088 px instead of 2048: a quarter of the memory.
int photoDecodeWidth(double logical, double dpr, {int cap = 2048}) {
  if (!logical.isFinite || logical <= 0) return cap;
  final pixels = (logical * dpr).ceil();
  return (((pixels + 63) ~/ 64) * 64).clamp(64, cap);
}

/// A photo loaded from a signed URL but cached by media id, so a fresh URL
/// for the same photo never downloads it again. Decoded at layout width x
/// device pixel ratio ([photoDecodeWidth]), not at full size.
class _Photo extends StatelessWidget {
  final PostMedia media;
  final BoxFit fit;
  const _Photo(this.media, {this.fit = BoxFit.cover});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = media.url;
    final blank = ColoredBox(color: scheme.surfaceContainerHighest);
    if (url.isEmpty) return blank;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) => Stack(
        fit: StackFit.expand,
        children: [
          blank,
          Image(
            image: ResizeImage.resizeIfNeeded(
              photoDecodeWidth(box.maxWidth, dpr),
              null,
              postPhotoFactory(url, 'media:${media.mediaId}:full'),
            ),
            fit: fit,
            excludeFromSemantics: true,
            frameBuilder: (_, child, frame, synchronous) => synchronous
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 150),
                    child: child,
                  ),
            errorBuilder: (_, _, _) => Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaCarousel extends StatefulWidget {
  final List<PostMedia> media;
  final VoidCallback onDoubleTap;
  const _MediaCarousel({required this.media, required this.onDoubleTap});
  @override
  State<_MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends State<_MediaCarousel> {
  int page = 0;
  bool burst = false;

  void doubleTap() {
    widget.onDoubleTap();
    setState(() => burst = true);
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => burst = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Portrait down to 4:5, landscape up to 1.91:1, like most photo feeds.
    final aspect = widget.media.first.aspect.clamp(0.8, 1.91);
    return AspectRatio(
      aspectRatio: aspect,
      child: GestureDetector(
        onDoubleTap: doubleTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              itemCount: widget.media.length,
              onPageChanged: (i) => setState(() => page = i),
              itemBuilder: (_, i) => _Photo(widget.media[i]),
            ),
            if (widget.media.length > 1) ...[
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${page + 1}/${widget.media.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < widget.media.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: i == page ? 16 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i == page ? Colors.white : Colors.white60,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            IgnorePointer(
              child: AnimatedScale(
                scale: burst ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: const Center(
                  child: Text('❤️', style: TextStyle(fontSize: 96)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 2, 8),
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
                    child: _Avatar.of(post.author, radius: 22),
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
                      onTap: () => _postMenu(context, ref, post, mode),
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
            ),
            if (post.body.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  statement ? 4 : 0,
                  18,
                  statement ? 14 : 12,
                ),
                child: Text(
                  post.body,
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
              ),
            if (post.media.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(VibeRadius.surface - 6),
                  child: _MediaCarousel(
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 2, 6),
                child: Row(
                  children: [
                    _ReactButton(post: post, onReact: react),
                    const SizedBox(width: 8),
                    _ActionPill(
                      key: Key('comments-${post.postId}'),
                      semanticLabel: post.commentCount == 0
                          ? 'Comment'
                          : '${post.commentCount} comments',
                      onTap: () => showComments(context, ref, post, mode),
                      icon: const Icon(Icons.mode_comment_outlined, size: 20),
                      label: post.commentCount == 0
                          ? ''
                          : '${post.commentCount}',
                    ),
                    const Spacer(),
                    Tooltip(
                      message: post.saved ? 'Remove from saved' : 'Save',
                      child: PressScale(
                        key: Key('save-${post.postId}'),
                        minHeight: 48,
                        semanticLabel: post.saved
                            ? 'Remove from saved'
                            : 'Save',
                        onTap: () =>
                            guarded(() => feed.toggleSave(post.postId)),
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A chunky pill in a post's action bar: an icon or emoji and a count.
class _ActionPill extends StatelessWidget {
  final Widget icon;
  final String label, semanticLabel;
  final String? semanticHint;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ActionPill({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.semanticHint,
    this.onLongPress,
    this.active = false,
  });
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PressScale(
      minHeight: 48,
      semanticLabel: semanticLabel,
      semanticHint: semanticHint,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Align(
        widthFactor: 1,
        child: AnimatedContainer(
          duration: VibeMotion.duration(context),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: active
                ? VibeColors.lime.withValues(alpha: dark ? .2 : .6)
                : (dark
                      ? Colors.white.withValues(alpha: .09)
                      : VibeColors.ink.withValues(alpha: .06)),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: active ? VibeColors.lime : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              if (label.isNotEmpty) ...[
                const SizedBox(width: 7),
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactButton extends StatelessWidget {
  final Post post;
  final void Function(String?) onReact;
  const _ReactButton({required this.post, required this.onReact});

  Future<void> pick(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final e in postReactions.entries)
                IconButton(
                  key: Key('reaction-${e.key}'),
                  tooltip: e.key,
                  iconSize: 36,
                  onPressed: () => Navigator.pop(sheet, e.key),
                  icon: Text(e.value, style: const TextStyle(fontSize: 32)),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice != null) onReact(choice);
  }

  @override
  Widget build(BuildContext context) {
    final mine = post.myReaction;
    final scheme = Theme.of(context).colorScheme;
    return _ActionPill(
      key: Key('react-${post.postId}'),
      active: mine != null,
      semanticLabel: mine == null ? 'React' : 'Remove reaction',
      semanticHint: 'Long press for more reactions',
      onTap: () => onReact(mine == null ? 'heart' : null),
      onLongPress: () => pick(context),
      icon: mine == null
          ? Icon(
              Icons.favorite_border_rounded,
              size: 21,
              color: scheme.onSurface,
            )
          : Text(
              postReactions[mine] ?? '❤️',
              style: const TextStyle(fontSize: 18),
            ),
      label: post.reactionCount == 0 ? '' : '${post.reactionCount}',
    );
  }
}

Future<void> _postMenu(
  BuildContext context,
  WidgetRef ref,
  Post post,
  String mode,
) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (post.mine)
              ListTile(
                key: const Key('delete-post'),
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(sheet).colorScheme.error,
                ),
                title: Text(
                  'Delete post',
                  style: TextStyle(color: Theme.of(sheet).colorScheme.error),
                ),
                onTap: () => Navigator.pop(sheet, 'delete'),
              )
            else ...[
              ListTile(
                key: const Key('mute-author'),
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text('Mute ${post.author.name}'),
                subtitle: const Text(
                  'Their posts leave your Pulse. They won’t know.',
                ),
                onTap: () => Navigator.pop(sheet, 'mute'),
              ),
              ListTile(
                key: const Key('report-post'),
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report post'),
                onTap: () => Navigator.pop(sheet, 'report'),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return;
  final api = ref.read(apiProvider);
  // The post's card can be gone (deleted, scrolled away) by the time the
  // server answers; the container outlives it.
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    switch (choice) {
      case 'delete':
        final sure = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Delete this post?'),
            content: const Text(
              'It disappears for everyone, along with its photos and comments.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirm-delete-post'),
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (sure != true) return;
        await api.deletePost(session, post.postId);
        container.invalidate(profilePostsProvider);
        for (final m in ['following', 'everyone']) {
          container.read(feedProvider(m).notifier).remove(post.postId);
        }
        if (context.mounted) showMessage(context, 'Post deleted.');
      case 'mute':
        await api.setMuted(session, post.author.userId, true);
        for (final m in ['following', 'everyone']) {
          container.invalidate(feedProvider(m));
        }
        if (context.mounted) {
          showMessage(context, '${post.author.name} is muted.');
        }
      case 'report':
        await showReportSheet(
          context,
          ref,
          targetType: 'post',
          targetId: post.postId,
          name: post.author.name,
        );
    }
  } catch (e) {
    if (context.mounted) showFailure(context, e);
  }
}

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

  Session get session => ref.read(sessionProvider).asData!.value!;

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
      final page = await ref
          .read(apiProvider)
          .comments(session, widget.post.postId, more ? next : null);
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
      final comment = await ref
          .read(apiProvider)
          .addComment(
            session,
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
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () => Navigator.pop(sheet, 'reply'),
            ),
            if (c.canDelete)
              ListTile(
                key: const Key('delete-comment'),
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete comment'),
                onTap: () => Navigator.pop(sheet, 'delete'),
              ),
            if (!c.mine)
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report comment'),
                onTap: () => Navigator.pop(sheet, 'report'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'reply':
        setState(() => replyTo = c);
      case 'delete':
        final feed = _feed;
        try {
          await ref.read(apiProvider).deleteComment(session, c.commentId);
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
    final byId = {
      for (final c in list ?? const <PostComment>[]) c.commentId: c,
    };
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
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final c in list)
                        ListTile(
                          key: Key('comment-${c.commentId}'),
                          contentPadding: EdgeInsets.only(
                            left: c.parentId == null ? 4 : 40,
                            right: 4,
                          ),
                          leading: _Avatar.of(c.author, radius: 16),
                          title: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: c.author.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                TextSpan(
                                  text: '  ${shortAgo(c.createdAt)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          subtitle: Text(
                            c.parentId != null && byId[c.parentId] != null
                                ? '@${byId[c.parentId]!.author.username} ${c.body}'
                                : c.body,
                            style: TextStyle(
                              color: scheme.onSurface,
                              height: 1.4,
                            ),
                          ),
                          onLongPress: () => options(c),
                          trailing: IconButton(
                            tooltip: 'Comment options',
                            icon: const Icon(Icons.more_vert_rounded, size: 18),
                            onPressed: () => options(c),
                          ),
                        ),
                      if (next != null)
                        TextButton(
                          onPressed: loadingMore
                              ? null
                              : () => load(more: true),
                          child: const Text('Show more'),
                        ),
                    ],
                  ),
          ),
          if (replyTo != null)
            Container(
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(child: Text('Replying to ${replyTo!.author.name}')),
                  IconButton(
                    tooltip: 'Cancel reply',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() => replyTo = null),
                  ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('comment-input'),
                      controller: input,
                      maxLength: 1000,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => send(),
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
                    onPressed: sending ? null : send,
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A photo picked for a post or story, uploading as soon as it's chosen.
class PendingPhoto {
  final Uint8List bytes;
  String? mediaId;
  double progress = 0;
  String? error;

  /// Set when a limit stopped the upload: retrying at once cannot work, so the tile offers no retry.
  bool limited = false;
  PendingPhoto(this.bytes);
  bool get done => mediaId != null;
}

Future<void> uploadPendingPhoto(
  WidgetRef ref,
  PendingPhoto p,
  String purpose,
  void Function() changed, {
  void Function(String message)? onLimit,
}) async {
  final type = sniffImageType(p.bytes);
  if (type == null) {
    p.error = 'Use a JPEG, PNG or WebP photo';
    changed();
    return;
  }
  try {
    p.error = null;
    p.mediaId = await ref
        .read(apiProvider)
        .uploadPhoto(
          ref.read(sessionProvider).asData!.value!,
          p.bytes,
          contentType: type,
          purpose: purpose,
          onProgress: (v) {
            p.progress = v;
            changed();
          },
        );
  } catch (e) {
    if (e is ApiFailure && e.code == 'QUOTA') {
      // The server's own calm words go in a message; the tile only says why it stopped.
      p.limited = true;
      p.error = 'Photo limit reached';
      onLimit?.call(e.displayMessage);
    } else {
      p.error = e is ApiFailure ? e.displayMessage : 'Upload failed';
    }
  }
  changed();
}

/// Writing a post: text, up to 10 photos, and who sees it.
class ComposePostScreen extends ConsumerStatefulWidget {
  final ImagePicker? picker;
  const ComposePostScreen({super.key, this.picker});
  @override
  ConsumerState<ComposePostScreen> createState() => _ComposePostScreenState();
}

class _ComposePostScreenState extends ConsumerState<ComposePostScreen> {
  final body = TextEditingController();
  final photos = <PendingPhoto>[];
  String? audience;
  bool sharing = false;

  ImagePicker get picker => widget.picker ?? ImagePicker();

  @override
  void dispose() {
    body.dispose();
    super.dispose();
  }

  bool get ready =>
      !sharing &&
      photos.every((p) => p.done) &&
      (body.text.trim().isNotEmpty || photos.isNotEmpty);

  /// Text or photos that leaving would throw away.
  bool get dirty => body.text.trim().isNotEmpty || photos.isNotEmpty;

  void close() => context.canPop() ? context.pop() : context.go('/home');

  /// Asks before discarding a draft, then leaves.
  Future<void> leave() async {
    if (!dirty || sharing) return close();
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this post?'),
        content: const Text('What you wrote and any photos will be lost.'),
        actions: [
          TextButton(
            key: const Key('keep-editing'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            key: const Key('discard-post'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) close();
  }

  Future<void> addPhotos() async {
    final room = 10 - photos.length;
    if (room <= 0) return;
    final files = await picker.pickMultiImage(
      limit: room > 1 ? room : null,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    for (final f in files.take(room)) {
      final p = PendingPhoto(await f.readAsBytes());
      if (!mounted) return;
      setState(() => photos.add(p));
      unawaited(
        uploadPendingPhoto(ref, p, 'post', () {
          if (mounted) setState(() {});
        }, onLimit: (m) => mounted ? showMessage(context, m) : null),
      );
    }
  }

  Future<void> share(String chosen) async {
    setState(() => sharing = true);
    try {
      final post = await ref
          .read(apiProvider)
          .createPost(
            ref.read(sessionProvider).asData!.value!,
            body: body.text.trim(),
            audience: chosen,
            mediaIds: [for (final p in photos) p.mediaId!],
          );
      ref.read(feedProvider('following').notifier).prepend(post);
      ref.invalidate(profilePostsProvider);
      if (chosen == 'public') {
        ref.read(feedProvider('everyone').notifier).prepend(post);
      }
      if (mounted) {
        showMessage(context, 'Shared.');
        context.canPop() ? context.pop() : context.go('/home');
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider).asData?.value;
    final chosen =
        audience ??
        defaultAudience(
          ref.watch(privacyProvider).asData?.value.values['profileAudience']
              as String?,
        );
    return PopScope(
      // System Back and the swipe gesture ask first when there is a draft.
      canPop: !dirty || sharing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            onPressed: leave,
          ),
          title: const Text('New post'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                key: const Key('share-post'),
                onPressed: ready ? () => share(chosen) : null,
                child: Text(sharing ? 'Sharing…' : 'Share'),
              ),
            ),
          ],
        ),
        body: ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Avatar(
                    profile?.displayName ?? '?',
                    userId: profile?.userId ?? '',
                    avatarUrl: profile?.avatarUrl,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('post-body'),
                      controller: body,
                      autofocus: true,
                      maxLength: 2200,
                      minLines: 3,
                      maxLines: 12,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'What’s the vibe?',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 110,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in photos)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            width: 110,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.memory(
                                  p.bytes,
                                  fit: BoxFit.cover,
                                  cacheWidth: 330,
                                ),
                                if (!p.done && p.error == null)
                                  ColoredBox(
                                    color: Colors.black38,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        value: p.progress > 0
                                            ? p.progress
                                            : null,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                if (p.error != null)
                                  Material(
                                    color: Colors.black54,
                                    child: InkWell(
                                      onTap: p.limited
                                          ? null
                                          : () => uploadPendingPhoto(
                                              ref,
                                              p,
                                              'post',
                                              () {
                                                if (mounted) setState(() {});
                                              },
                                            ),
                                      child: Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: Text(
                                            p.limited
                                                ? p.error!
                                                : '${p.error!}\nTap to retry',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: IconButton.filled(
                                    tooltip: 'Remove photo',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 16,
                                    style: IconButton.styleFrom(
                                      backgroundColor: Colors.black54,
                                    ),
                                    onPressed: () =>
                                        setState(() => photos.remove(p)),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (photos.length < 10)
                      InkWell(
                        key: const Key('add-photos'),
                        borderRadius: BorderRadius.circular(14),
                        onTap: addPhotos,
                        child: Container(
                          width: 110,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.add_photo_alternate_outlined),
                              const SizedBox(height: 6),
                              Text(
                                photos.isEmpty
                                    ? 'Add photos'
                                    : '${photos.length}/10',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Who can see this?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const Key('post-audience'),
                segments: [
                  for (final e in audienceLabels.entries)
                    ButtonSegment(
                      value: e.key,
                      label: Text(e.value),
                      icon: Icon(audienceIcon(e.key)),
                    ),
                ],
                selected: {chosen},
                onSelectionChanged: (s) => setState(() => audience = s.single),
              ),
              const SizedBox(height: 12),
              Text(
                'Photos are re-saved without location or camera details before anyone sees them.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stories from the viewer's circle, own first, with a way to add one.
class StoryTray extends ConsumerWidget {
  const StoryTray({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups =
        ref.watch(storyTrayProvider).asData?.value ?? const <StoryGroup>[];
    final mine = groups.where((g) => g.mine).firstOrNull;
    final others = [
      for (final g in groups)
        if (!g.mine) g,
    ];
    final viewable = [?mine, ...others];
    final profile = ref.watch(profileProvider).asData?.value;
    void open(StoryGroup g) =>
        openStories(context, viewable, viewable.indexOf(g));
    // Labels may grow with the reader's text size, up to 1.4×.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: SizedBox(
        height: 104 + scaler.scale(17),
        child: ScrollConfiguration(
          behavior: const DragAnywhereBehavior(),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _StoryBubble(
                key: const Key('story-mine'),
                name: profile?.displayName ?? 'You',
                userId: profile?.userId ?? '',
                avatarUrl: profile?.avatarUrl,
                label: 'Your story',
                ring: mine == null ? _Ring.none : _Ring.unseen,
                add: true,
                onTap: mine == null
                    ? () => context.push('/story/new')
                    : () => open(mine),
                onAdd: () => context.push('/story/new'),
              ),
              for (final g in others)
                _StoryBubble(
                  key: Key('story-${g.author.userId}'),
                  name: g.author.name,
                  userId: g.author.userId,
                  avatarUrl: g.author.avatarUrl,
                  label: g.author.name,
                  ring: g.allSeen ? _Ring.seen : _Ring.unseen,
                  onTap: () => open(g),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The ring around a story avatar: bright when there is something new, quiet
/// once it has been watched, absent when there is no story at all.
enum _Ring { none, seen, unseen }

class _StoryBubble extends StatefulWidget {
  final String name, label, userId;
  final String? avatarUrl;
  final _Ring ring;
  final bool add;
  final VoidCallback onTap;
  final VoidCallback? onAdd;
  const _StoryBubble({
    super.key,
    required this.name,
    required this.label,
    required this.onTap,
    this.userId = '',
    this.avatarUrl,
    this.ring = _Ring.none,
    this.add = false,
    this.onAdd,
  });
  @override
  State<_StoryBubble> createState() => _StoryBubbleState();
}

class _StoryBubbleState extends State<_StoryBubble> {
  bool _pressed = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unseen = widget.ring == _Ring.unseen;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Semantics(
        button: true,
        label: widget.add && widget.ring == _Ring.none
            ? 'Add to your story'
            : 'Stories from ${widget.label}',
        excludeSemantics: true,
        child: InkWell(
          // The default hover and press highlight is a tall grey pill around the
          // avatar and its name. Feedback is a small press scale on the avatar and a
          // ring around it for keyboard focus instead.
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius: BorderRadius.circular(40),
          onHighlightChanged: (value) => setState(() => _pressed = value),
          onFocusChange: (value) => setState(() => _focused = value),
          onTap: widget.onTap,
          child: SizedBox(
            width: 82,
            child: Column(
              children: [
                AnimatedScale(
                  scale: _pressed ? 0.94 : 1,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 90),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _focused ? scheme.onSurface : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3.5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.ring == _Ring.seen
                                ? scheme.outlineVariant
                                : widget.ring == _Ring.none
                                ? scheme.outlineVariant.withValues(alpha: .6)
                                : null,
                            gradient: unseen
                                ? const SweepGradient(
                                    colors: [
                                      VibeColors.lime,
                                      Color(0xff2dd4bf),
                                      Color(0xffa855f7),
                                      Color(0xffff5c8a),
                                      VibeColors.lime,
                                    ],
                                  )
                                : null,
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.scaffoldBackgroundColor,
                            ),
                            child: _Avatar(
                              widget.name,
                              radius: 31,
                              userId: widget.userId,
                              avatarUrl: widget.avatarUrl,
                            ),
                          ),
                        ),
                        if (widget.add)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: GestureDetector(
                              onTap: widget.onAdd,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: VibeColors.lime,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: theme.scaffoldBackgroundColor,
                                    width: 3,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  size: 18,
                                  color: VibeColors.ink,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: widget.add ? FontWeight.w800 : FontWeight.w600,
                    color: widget.ring == _Ring.seen
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void openStories(BuildContext context, List<StoryGroup> groups, int start) {
  if (groups.isEmpty || start < 0) return;
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => StoryViewer(groups: groups, start: start),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// Full-screen stories: tap right for next, left for previous, hold to pause.
class StoryViewer extends ConsumerStatefulWidget {
  final List<StoryGroup> groups;
  final int start;
  const StoryViewer({super.key, required this.groups, required this.start});
  @override
  ConsumerState<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends ConsumerState<StoryViewer>
    with SingleTickerProviderStateMixin {
  static const shownFor = Duration(seconds: 5);
  late int group = widget.start;
  late int index = _firstUnseen(widget.groups[widget.start]);
  late final timer = AnimationController(vsync: this, duration: shownFor)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) next();
    });
  final viewed = <String>{};
  final removed = <String>{};

  /// Set once the viewer starts closing. The timer finishing, a tap and a
  /// swipe can all ask to close in the same frame; only the first pops.
  bool closing = false;

  static int _firstUnseen(StoryGroup g) {
    final i = g.stories.indexWhere((s) => !s.seen);
    return g.mine || i < 0 ? 0 : i;
  }

  List<Story> get stories => [
    for (final s in widget.groups[group].stories)
      if (!removed.contains(s.storyId)) s,
  ];

  @override
  void initState() {
    super.initState();
    show();
  }

  @override
  void dispose() {
    timer.dispose();
    super.dispose();
  }

  void show() {
    if (closing) return;
    final list = stories;
    if (list.isEmpty) {
      next();
      return;
    }
    index = index.clamp(0, list.length - 1);
    final story = list[index];
    final g = widget.groups[group];
    if (!g.mine && !story.seen && viewed.add(story.storyId)) {
      final session = ref.read(sessionProvider).asData?.value;
      if (session != null) {
        ref
            .read(apiProvider)
            .viewStory(session, story.storyId)
            .catchError((_) {});
      }
    }
    timer.forward(from: 0);
  }

  void close() {
    if (closing || !mounted) return;
    closing = true;
    timer.stop();
    ref.invalidate(storyTrayProvider);
    Navigator.of(context).pop();
  }

  void next() {
    if (closing) return;
    if (index + 1 < stories.length) {
      setState(() => index++);
    } else if (group + 1 < widget.groups.length) {
      setState(() {
        group++;
        index = _firstUnseen(widget.groups[group]);
      });
    } else {
      close();
      return;
    }
    show();
  }

  void previous() {
    if (closing) return;
    if (index > 0) {
      setState(() => index--);
    } else if (group > 0) {
      setState(() {
        group--;
        index = 0;
      });
    }
    show();
  }

  Future<void> menu(Story story, StoryGroup g) async {
    timer.stop();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (g.mine)
              ListTile(
                key: const Key('delete-story'),
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete story'),
                onTap: () => Navigator.pop(sheet, 'delete'),
              )
            else
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report story'),
                onTap: () => Navigator.pop(sheet, 'report'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (choice == 'delete' && session != null) {
      try {
        await ref.read(apiProvider).deleteStory(session, story.storyId);
        if (!mounted) return;
        setState(() => removed.add(story.storyId));
        show();
        return;
      } catch (e) {
        if (mounted) showFailure(context, e);
      }
    } else if (choice == 'report') {
      await showReportSheet(
        context,
        ref,
        targetType: 'story',
        targetId: story.storyId,
        name: g.author.name,
      );
    }
    if (mounted && !closing) timer.forward();
  }

  Future<void> viewers(Story story) async {
    timer.stop();
    final session = ref.read(sessionProvider).asData!.value!;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => FractionallySizedBox(
        heightFactor: .6,
        child: FutureBuilder(
          future: ref.read(apiProvider).storyViewers(session, story.storyId),
          builder: (context, snap) {
            final list = snap.data?.items;
            if (snap.hasError) {
              return const Center(child: Text('Couldn’t load viewers.'));
            }
            if (list == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (list.isEmpty) return const Center(child: Text('No views yet.'));
            return ListView(
              children: [
                for (final v in list)
                  ListTile(
                    leading: _Avatar.of(
                      Person.fromJson(v['user'] as Map),
                      radius: 18,
                    ),
                    title: Text(Person.fromJson(v['user'] as Map).name),
                    subtitle: Text(
                      shortAgo(DateTime.parse(v['since'] as String)),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (mounted && !closing) timer.forward();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.groups[group];
    final list = stories;
    if (list.isEmpty) return const ColoredBox(color: Colors.black);
    final story = list[index.clamp(0, list.length - 1)];
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) =>
            d.globalPosition.dx < MediaQuery.sizeOf(context).width / 3
            ? previous()
            : next(),
        onLongPressStart: (_) => timer.stop(),
        onLongPressEnd: (_) {
          if (!closing) timer.forward();
        },
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) close();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The same canvas the composer and My stories draw, so a story looks as it was made.
            StoryCanvas(
              key: ValueKey(story.storyId),
              background: story.background,
              textStyle: story.textStyle,
              body: story.body,
              photo: story.media == null ? null : _Photo(story.media!),
            ),
            // Keeps the white header readable on light photos and colours.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 160,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x73000000), Color(0x00000000)],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 4, 0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (var i = 0; i < list.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: AnimatedBuilder(
                                  animation: timer,
                                  builder: (_, _) => LinearProgressIndicator(
                                    minHeight: 3,
                                    value: i < index
                                        ? 1
                                        : (i == index ? timer.value : 0),
                                    color: Colors.white,
                                    backgroundColor: Colors.white30,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _Avatar.of(g.author, radius: 16),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${g.mine ? 'Your story' : g.author.name}  ·  ${shortAgo(story.createdAt)}${g.mine ? '  ·  ${storyTimeLeft(story.expiresAt)}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              shadows: [Shadow(blurRadius: 6)],
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Story options',
                          color: Colors.white,
                          icon: const Icon(Icons.more_horiz_rounded),
                          onPressed: () => menu(story, g),
                        ),
                        IconButton(
                          key: const Key('close-stories'),
                          tooltip: 'Close',
                          color: Colors.white,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: close,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (g.mine)
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: SafeArea(
                  child: Center(
                    child: FilledButton.tonalIcon(
                      key: const Key('story-viewers'),
                      onPressed: () => viewers(story),
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: Text('Seen by ${story.viewCount ?? 0}'),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

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
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final p in posts)
          Padding(
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
                        child: _Photo(p.media.first),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (p.body.isNotEmpty)
                          Text(
                            p.body,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
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
          ),
      ],
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  final List<PostMedia> photos;
  const _PhotoGrid({required this.photos});
  @override
  Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 3,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 4,
    crossAxisSpacing: 4,
    children: [
      for (final m in photos)
        Semantics(
          button: true,
          label: 'Open photo',
          child: GestureDetector(
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  body: InteractiveViewer(
                    child: Center(child: _Photo(m, fit: BoxFit.contain)),
                  ),
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _Photo(m),
            ),
          ),
        ),
    ],
  );
}
