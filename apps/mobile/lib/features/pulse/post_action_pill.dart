import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../shared/press_scale.dart';

/// A chunky pill in a post's action bar: an icon or emoji and a count.
class PostActionPill extends StatelessWidget {
  final Widget icon;
  final String label, semanticLabel;
  final String? semanticHint;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const PostActionPill({
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

class PostReactButton extends StatelessWidget {
  final Post post;
  final void Function(String?) onReact;
  const PostReactButton({super.key, required this.post, required this.onReact});

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
    return PostActionPill(
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
