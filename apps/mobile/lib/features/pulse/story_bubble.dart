import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'pulse_common.dart';

/// The ring around a story avatar: bright when there is something new, quiet
/// once it has been watched, absent when there is no story at all.
enum StoryRing { none, seen, unseen }

class StoryBubble extends StatefulWidget {
  final String name, label, userId;
  final String? avatarUrl;
  final StoryRing ring;
  final bool add;
  final VoidCallback onTap;
  final VoidCallback? onAdd;
  const StoryBubble({
    super.key,
    required this.name,
    required this.label,
    required this.onTap,
    this.userId = '',
    this.avatarUrl,
    this.ring = StoryRing.none,
    this.add = false,
    this.onAdd,
  });
  @override
  State<StoryBubble> createState() => _StoryBubbleState();
}

class _StoryBubbleState extends State<StoryBubble> {
  bool _pressed = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 10),
      child: Semantics(
        button: true,
        label: widget.add && widget.ring == StoryRing.none
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
                        _RingedAvatar(
                          name: widget.name,
                          userId: widget.userId,
                          avatarUrl: widget.avatarUrl,
                          ring: widget.ring,
                        ),
                        if (widget.add) _AddBadge(onAdd: widget.onAdd),
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
                    color: widget.ring == StoryRing.seen
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

class _RingedAvatar extends StatelessWidget {
  final String name, userId;
  final String? avatarUrl;
  final StoryRing ring;
  const _RingedAvatar({
    required this.name,
    required this.userId,
    required this.avatarUrl,
    required this.ring,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(3.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ring == StoryRing.seen
            ? scheme.outlineVariant
            : ring == StoryRing.none
            ? scheme.outlineVariant.withValues(alpha: .6)
            : null,
        gradient: ring == StoryRing.unseen
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
        child: PulseAvatar(
          name,
          radius: 31,
          userId: userId,
          avatarUrl: avatarUrl,
        ),
      ),
    );
  }
}

/// The small "+" on your own bubble, which opens the composer.
class _AddBadge extends StatelessWidget {
  final VoidCallback? onAdd;
  const _AddBadge({required this.onAdd});

  @override
  Widget build(BuildContext context) => PositionedDirectional(
    end: -2,
    bottom: -2,
    child: GestureDetector(
      onTap: onAdd,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: VibeColors.lime,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).scaffoldBackgroundColor,
            width: 3,
          ),
        ),
        child: const Icon(Icons.add_rounded, size: 18, color: VibeColors.ink),
      ),
    ),
  );
}
