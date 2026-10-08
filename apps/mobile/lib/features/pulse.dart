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
import '../shared/widgets.dart';
import 'safety.dart';

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

/// The photo type from its first bytes, or null if it isn't one we accept.
/// Uploads are labelled by content, never by file name.
String? sniffImageType(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length > 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length > 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  return null;
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

const storyColors = {
  'lime': VibeColors.lime,
  'lilac': VibeColors.lilac,
  'pink': VibeColors.pink,
  'mint': VibeColors.mint,
  'peach': VibeColors.peach,
  'ink': VibeColors.ink,
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
                subtitle: const Text('Gone in 24 hours'),
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

class _Avatar extends StatelessWidget {
  final String name;
  final double radius;
  const _Avatar(this.name, {this.radius = 20});
  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundColor: VibeColors.lilac,
    foregroundColor: VibeColors.ink,
    child: Text(
      name.replaceFirst('@', '').characters.firstOrNull?.toUpperCase() ?? '?',
      style: TextStyle(fontWeight: FontWeight.w800, fontSize: radius * .8),
    ),
  );
}

/// A photo loaded from a signed URL but cached by media id, so a fresh URL
/// for the same photo never downloads it again.
class _Photo extends StatelessWidget {
  final PostMedia media;
  final BoxFit fit;
  const _Photo(this.media, {this.fit = BoxFit.cover});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = media.url;
    if (url.isEmpty) return ColoredBox(color: scheme.surfaceContainerHighest);
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: 'media:${media.mediaId}:full',
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, _) => ColoredBox(color: scheme.surfaceContainerHighest),
      errorWidget: (_, _, _) => ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Icon(
          Icons.broken_image_outlined,
          color: scheme.onSurfaceVariant,
        ),
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
        if (context.mounted) showMessage(context, e.toString());
      }
    }

    void react(String? reaction) =>
        guarded(() => feed.react(post.postId, reaction));

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
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
              padding: const EdgeInsets.fromLTRB(14, 12, 4, 8),
              child: Row(
                children: [
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => context.go(
                      post.mine
                          ? '/profile'
                          : '/discover/person/${post.author.userId}',
                    ),
                    child: _Avatar(post.author.name),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          post.author.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                '@${post.author.username} · ${shortAgo(post.createdAt)} · ',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
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
                  IconButton(
                    key: Key('post-menu-${post.postId}'),
                    tooltip: 'Post options',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onPressed: () => _postMenu(context, ref, post, mode),
                  ),
                ],
              ),
            ),
            if (post.body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  post.body,
                  style: const TextStyle(fontSize: 15, height: 1.45),
                ),
              ),
            if (post.media.isNotEmpty)
              _MediaCarousel(
                media: post.media,
                onDoubleTap: () {
                  if (post.myReaction == null) react('heart');
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
              child: Row(
                children: [
                  _ReactButton(post: post, onReact: react),
                  TextButton.icon(
                    key: Key('comments-${post.postId}'),
                    onPressed: () => showComments(context, ref, post, mode),
                    icon: const Icon(Icons.mode_comment_outlined, size: 20),
                    label: Text(
                      post.commentCount == 0
                          ? 'Comment'
                          : '${post.commentCount}',
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: Key('save-${post.postId}'),
                    tooltip: post.saved ? 'Remove from saved' : 'Save',
                    onPressed: () =>
                        guarded(() => feed.toggleSave(post.postId)),
                    icon: Icon(
                      post.saved
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
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
    return Semantics(
      button: true,
      label: mine == null ? 'React' : 'Remove reaction',
      hint: 'Long press for more reactions',
      child: InkWell(
        key: Key('react-${post.postId}'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => onReact(mine == null ? 'heart' : null),
        onLongPress: () => pick(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mine == null)
                Icon(
                  Icons.favorite_border_rounded,
                  size: 21,
                  color: scheme.onSurface,
                )
              else
                Text(
                  postReactions[mine] ?? '❤️',
                  style: const TextStyle(fontSize: 18),
                ),
              const SizedBox(width: 6),
              Text(
                post.reactionCount == 0 ? 'React' : '${post.reactionCount}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
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
        ref.invalidate(profilePostsProvider);
        for (final m in ['following', 'everyone']) {
          ref.read(feedProvider(m).notifier).remove(post.postId);
        }
        if (context.mounted) showMessage(context, 'Post deleted.');
      case 'mute':
        await api.setMuted(session, post.author.userId, true);
        for (final m in ['following', 'everyone']) {
          ref.invalidate(feedProvider(m));
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
    if (context.mounted) showMessage(context, e.toString());
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
  bool sending = false;

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
    try {
      final page = await ref
          .read(apiProvider)
          .comments(session, widget.post.postId, more ? next : null);
      if (!mounted) return;
      setState(() {
        items = [...more ? items ?? const [] : const [], ...page.items];
        next = page.nextCursor;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final comment = await ref
          .read(apiProvider)
          .addComment(
            session,
            widget.post.postId,
            text,
            parentId: replyTo?.commentId,
          );
      ref
          .read(feedProvider(widget.mode).notifier)
          .commentCountChanged(widget.post.postId, 1);
      if (!mounted) return;
      input.clear();
      setState(() {
        // New comments land at the end once every older page is loaded.
        if (next == null) items = [...?items, comment];
        replyTo = null;
      });
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
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
        try {
          await ref.read(apiProvider).deleteComment(session, c.commentId);
          ref
              .read(feedProvider(widget.mode).notifier)
              .commentCountChanged(widget.post.postId, -1);
          if (mounted) {
            setState(
              () =>
                  items = [...?items?.where((x) => x.commentId != c.commentId)],
            );
          }
        } catch (e) {
          if (mounted) showMessage(context, e.toString());
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
                          leading: _Avatar(c.author.name, radius: 16),
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
                          onPressed: () => load(more: true),
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
class _Pending {
  final Uint8List bytes;
  String? mediaId;
  double progress = 0;
  String? error;
  _Pending(this.bytes);
  bool get done => mediaId != null;
}

Future<void> _upload(
  WidgetRef ref,
  _Pending p,
  String purpose,
  void Function() changed,
) async {
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
    p.error = e is ApiFailure ? e.message : 'Upload failed';
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
  final photos = <_Pending>[];
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
      final p = _Pending(await f.readAsBytes());
      if (!mounted) return;
      setState(() => photos.add(p));
      unawaited(
        _upload(ref, p, 'post', () {
          if (mounted) setState(() {});
        }),
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
      if (mounted) showMessage(context, e.toString());
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
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
                _Avatar(profile?.displayName ?? '?'),
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
                                      value: p.progress > 0 ? p.progress : null,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              if (p.error != null)
                                Material(
                                  color: Colors.black54,
                                  child: InkWell(
                                    onTap: () => _upload(ref, p, 'post', () {
                                      if (mounted) setState(() {});
                                    }),
                                    child: Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(6),
                                        child: Text(
                                          '${p.error!}\nTap to retry',
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
        height: 80 + scaler.scale(17),
        child: ListView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          children: [
            _StoryBubble(
              key: const Key('story-mine'),
              name: profile?.displayName ?? 'You',
              label: 'Your story',
              ring: mine == null ? null : VibeColors.lime,
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
                label: g.author.name,
                ring: g.allSeen
                    ? Theme.of(context).colorScheme.outlineVariant
                    : VibeColors.lime,
                onTap: () => open(g),
              ),
          ],
        ),
      ),
    );
  }
}

class _StoryBubble extends StatelessWidget {
  final String name, label;
  final Color? ring;
  final bool add;
  final VoidCallback onTap;
  final VoidCallback? onAdd;
  const _StoryBubble({
    super.key,
    required this.name,
    required this.label,
    required this.onTap,
    this.ring,
    this.add = false,
    this.onAdd,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Semantics(
        button: true,
        label: add && ring == null
            ? 'Add to your story'
            : 'Stories from $label',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(40),
          onTap: onTap,
          child: SizedBox(
            width: 70,
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: ring ?? Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: _Avatar(name, radius: 27),
                    ),
                    if (add)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: GestureDetector(
                          onTap: onAdd,
                          child: Container(
                            decoration: BoxDecoration(
                              color: VibeColors.ink,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.surface,
                                width: 2,
                              ),
                            ),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(
                              Icons.add_rounded,
                              size: 16,
                              color: VibeColors.lime,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
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
    ref.invalidate(storyTrayProvider);
    Navigator.of(context).pop();
  }

  void next() {
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
        setState(() => removed.add(story.storyId));
        show();
        return;
      } catch (e) {
        if (mounted) showMessage(context, e.toString());
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
    if (mounted) timer.forward();
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
                    leading: _Avatar(
                      Person.fromJson(v['user'] as Map).name,
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
    if (mounted) timer.forward();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.groups[group];
    final list = stories;
    if (list.isEmpty) return const ColoredBox(color: Colors.black);
    final story = list[index.clamp(0, list.length - 1)];
    final bg = storyColors[story.background] ?? VibeColors.lime;
    final ink = story.background == 'ink' ? VibeColors.cream : VibeColors.ink;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) =>
            d.globalPosition.dx < MediaQuery.sizeOf(context).width / 3
            ? previous()
            : next(),
        onLongPressStart: (_) => timer.stop(),
        onLongPressEnd: (_) => timer.forward(),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) close();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (story.media != null)
              Center(child: _Photo(story.media!, fit: BoxFit.contain))
            else
              ColoredBox(
                color: bg,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      story.body,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 32,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  ),
                ),
              ),
            if (story.media != null && story.body.isNotEmpty)
              Positioned(
                left: 24,
                right: 24,
                bottom: 120,
                child: Text(
                  story.body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(blurRadius: 8)],
                  ),
                ),
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
                        _Avatar(g.author.name, radius: 16),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${g.mine ? 'Your story' : g.author.name}  ·  ${shortAgo(story.createdAt)}',
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

/// Making a story: a photo, or words on a colour.
class StoryComposerScreen extends ConsumerStatefulWidget {
  final ImagePicker? picker;
  const StoryComposerScreen({super.key, this.picker});
  @override
  ConsumerState<StoryComposerScreen> createState() =>
      _StoryComposerScreenState();
}

class _StoryComposerScreenState extends ConsumerState<StoryComposerScreen> {
  final text = TextEditingController();
  _Pending? photo;
  String background = 'lime';
  String? audience;
  bool sharing = false;

  ImagePicker get picker => widget.picker ?? ImagePicker();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> pick(ImageSource source) async {
    final file = await picker.pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (file == null) return;
    final p = _Pending(await file.readAsBytes());
    if (!mounted) return;
    setState(() => photo = p);
    await _upload(ref, p, 'story', () {
      if (mounted) setState(() {});
    });
  }

  bool get ready =>
      !sharing && (photo == null ? text.text.trim().isNotEmpty : photo!.done);

  Future<void> share(String chosen) async {
    setState(() => sharing = true);
    try {
      await ref
          .read(apiProvider)
          .createStory(
            ref.read(sessionProvider).asData!.value!,
            body: text.text.trim(),
            background: background,
            mediaId: photo?.mediaId,
            audience: chosen,
          );
      ref.invalidate(storyTrayProvider);
      if (mounted) {
        showMessage(context, 'Added to your story.');
        context.canPop() ? context.pop() : context.go('/home');
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final setting =
        ref.watch(privacyProvider).asData?.value.values['storyAudience']
            as String?;
    final chosen = audience ?? defaultAudience(setting);
    final bg = storyColors[background]!;
    final ink = background == 'ink' ? VibeColors.cream : VibeColors.ink;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Your story'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const Key('share-story'),
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
            AspectRatio(
              aspectRatio: 9 / 14,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: photo != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(photo!.bytes, fit: BoxFit.cover),
                          if (!photo!.done)
                            ColoredBox(
                              color: Colors.black38,
                              child: Center(
                                child: photo!.error != null
                                    ? Text(
                                        photo!.error!,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      )
                                    : CircularProgressIndicator(
                                        value: photo!.progress > 0
                                            ? photo!.progress
                                            : null,
                                        color: Colors.white,
                                      ),
                              ),
                            ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: IconButton.filled(
                              tooltip: 'Remove photo',
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                              ),
                              onPressed: () => setState(() => photo = null),
                              icon: const Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      )
                    : ColoredBox(
                        color: bg,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: TextField(
                              key: const Key('story-text'),
                              controller: text,
                              maxLength: 280,
                              maxLines: null,
                              textAlign: TextAlign.center,
                              onChanged: (_) => setState(() {}),
                              style: TextStyle(
                                fontFamily: 'SpaceGrotesk',
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: ink,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Say something…',
                                hintStyle: TextStyle(
                                  color: ink.withValues(alpha: .5),
                                ),
                                border: InputBorder.none,
                                counterText: '',
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 14),
            if (photo == null)
              Wrap(
                spacing: 10,
                children: [
                  for (final e in storyColors.entries)
                    Semantics(
                      button: true,
                      selected: e.key == background,
                      label: '${e.key} background',
                      child: GestureDetector(
                        onTap: () => setState(() => background = e.key),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: e.value,
                            shape: BoxShape.circle,
                            border: Border.all(
                              width: e.key == background ? 3 : 1,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('story-gallery'),
                    onPressed: () => pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Photo'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Camera'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Who can see this?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
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
