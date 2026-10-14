import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/feed_state.dart';
import '../../core/user_error.dart';
import '../../shared/widgets.dart';
import '../safety.dart';
import 'profile_content.dart';
import 'pulse_actions.dart';

Future<void> showPostMenu(
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
    builder: (_) => _PostMenuSheet(post: post),
  );
  if (choice == null || !context.mounted) return;
  final actions = ref.read(pulseActionsProvider);
  if (!actions.hasSession) return;
  // The post's card can be gone (deleted, scrolled away) by the time the
  // server answers; the container outlives it.
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    switch (choice) {
      case 'delete':
        final sure = await _confirmDelete(context);
        if (sure != true) return;
        await actions.deletePost(post.postId);
        container.invalidate(profilePostsProvider);
        for (final m in ['following', 'everyone']) {
          container.read(feedProvider(m).notifier).remove(post.postId);
        }
        if (context.mounted) showMessage(context, 'Post deleted.');
      case 'mute':
        await actions.setMuted(post.author.userId, true);
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

Future<bool?> _confirmDelete(BuildContext context) => showDialog<bool>(
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

class _PostMenuSheet extends StatelessWidget {
  final Post post;
  const _PostMenuSheet({required this.post});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (post.mine)
            ListTile(
              key: const Key('delete-post'),
              leading: Icon(
                Icons.delete_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete post',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            )
          else ...[
            ListTile(
              key: const Key('mute-author'),
              leading: const Icon(Icons.notifications_off_outlined),
              title: Text('Mute ${post.author.name}'),
              subtitle: const Text(
                'Their posts leave your Pulse. They won’t know.',
              ),
              onTap: () => Navigator.pop(context, 'mute'),
            ),
            ListTile(
              key: const Key('report-post'),
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report post'),
              onTap: () => Navigator.pop(context, 'report'),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
