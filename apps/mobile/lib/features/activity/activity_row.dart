import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../shared/person_avatar.dart';
import 'activity_labels.dart';

(IconData, Color) _typeStyle(String type) => switch (type) {
  'like' || 'reaction' => (Icons.favorite_border_rounded, VibeColors.pink),
  'comment' => (Icons.chat_bubble_outline_rounded, VibeColors.lilac),
  'visit' => (Icons.visibility_outlined, VibeColors.mint),
  'follow' ||
  'friend_request' => (Icons.person_add_alt_1_outlined, VibeColors.lime),
  'community' => (Icons.groups_outlined, VibeColors.lime),
  'message' || 'message_request' => (Icons.forum_outlined, VibeColors.mint),
  'security' => (Icons.shield_outlined, VibeColors.peach),
  'moderation' => (Icons.info_outline_rounded, VibeColors.lilac),
  _ => (Icons.auto_awesome_outlined, VibeColors.lilac),
};

class ActivityRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final DateTime now;
  final VoidCallback? onOpen, onMarkRead, onDismiss;
  final ImageProvider? Function(Map<String, dynamic>)? avatarImage;
  final Widget? actions;
  const ActivityRow({
    super.key,
    required this.item,
    required this.now,
    this.onOpen,
    this.onMarkRead,
    this.onDismiss,
    this.avatarImage,
    this.actions,
  });
  @override
  Widget build(BuildContext context) {
    final unread = item['readAt'] == null;
    final actors = (item['actors'] as List? ?? []).cast<Map<String, dynamic>>();
    final (icon, tint) = _typeStyle(item['type'] as String? ?? '');
    return Semantics(
      container: true,
      label: unread ? 'Unread activity' : 'Read activity',
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 20, end: 8),
                child: SizedBox(
                  width: 6,
                  height: 6,
                  child: unread
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            color: VibeColors.lime,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
              ),
              _ActivityLeading(
                actors: actors,
                icon: icon,
                tint: tint,
                avatarImage: avatarImage,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActivityBody(
                  item: item,
                  now: now,
                  unread: unread,
                  actions: actions,
                ),
              ),
              if ((unread && onMarkRead != null) || onDismiss != null)
                _ActivityMenu(
                  unread: unread,
                  onMarkRead: onMarkRead,
                  onDismiss: onDismiss,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Actor avatars (up to two, overlapped) with the notification type badge, or
/// a tinted type tile when no actor is known.
class _ActivityLeading extends StatelessWidget {
  final List<Map<String, dynamic>> actors;
  final IconData icon;
  final Color tint;
  final ImageProvider? Function(Map<String, dynamic>)? avatarImage;
  const _ActivityLeading({
    required this.actors,
    required this.icon,
    required this.tint,
    this.avatarImage,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: actors.length > 1 ? 60 : 48,
      height: 52,
      child: Stack(
        children: [
          if (actors.isEmpty)
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(icon, size: 20, color: scheme.onSurface),
            ),
          for (var i = math.min(actors.length, 2) - 1; i >= 0; i--)
            PositionedDirectional(
              start: i * 12,
              top: i * 4,
              child: ActorAvatar(
                actor: actors[i],
                tint: tint,
                image: avatarImage?.call(actors[i]),
              ),
            ),
          if (actors.isNotEmpty)
            PositionedDirectional(
              end: 0,
              bottom: 0,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: tint,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    width: 2,
                  ),
                ),
                child: Icon(icon, size: 11, color: VibeColors.ink),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActivityBody extends StatelessWidget {
  final Map<String, dynamic> item;
  final DateTime now;
  final bool unread;
  final Widget? actions;
  const _ActivityBody({
    required this.item,
    required this.now,
    required this.unread,
    this.actions,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = item['text'] as String? ?? '';
    final count = item['count'] as int? ?? 1;
    final timestamp = activityTimeLabel(item, now, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (timestamp.isNotEmpty)
              Text(
                timestamp,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            if (count > 1)
              Text(
                '$count updates',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            if (unread)
              Text(
                'New',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        if (actions != null) ...[const SizedBox(height: 12), actions!],
      ],
    );
  }
}

class _ActivityMenu extends StatelessWidget {
  final bool unread;
  final VoidCallback? onMarkRead, onDismiss;
  const _ActivityMenu({required this.unread, this.onMarkRead, this.onDismiss});
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Activity actions',
    iconSize: 18,
    onSelected: (action) {
      if (action == 'read') {
        onMarkRead?.call();
      } else {
        onDismiss?.call();
      }
    },
    itemBuilder: (_) => [
      if (unread && onMarkRead != null)
        const PopupMenuItem(value: 'read', child: Text('Mark as read')),
      if (onDismiss != null)
        const PopupMenuItem(value: 'dismiss', child: Text('Dismiss')),
    ],
  );
}

class ActorAvatar extends StatelessWidget {
  final Map<String, dynamic> actor;
  final Color tint;
  final ImageProvider? image;
  const ActorAvatar({
    super.key,
    required this.actor,
    required this.tint,
    this.image,
  });
  @override
  Widget build(BuildContext context) {
    final name = actor['displayName'] as String? ?? '';
    final avatar = PersonAvatar(
      name: name,
      avatarUrl: image == null ? actor['avatarUrl'] as String? : null,
      userId: actor['userId'] as String? ?? '',
      radius: 20,
      tint: tint,
      initialStyle: const TextStyle(
        fontFamily: 'SpaceGrotesk',
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).scaffoldBackgroundColor,
            width: 2,
          ),
        ),
        child: image == null
            ? avatar
            : ClipOval(
                child: Image(
                  image: ResizeImage.resizeIfNeeded(96, 96, image!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => avatar,
                ),
              ),
      ),
    );
  }
}
