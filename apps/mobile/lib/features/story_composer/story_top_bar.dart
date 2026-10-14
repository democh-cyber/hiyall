import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'story_char_ring.dart';
import 'story_tap.dart';

/// Close, the character ring and the Share button.
class StoryTopBar extends StatelessWidget {
  final int count;
  final bool ready, sharing;
  final VoidCallback onClose;
  final VoidCallback onShare;
  const StoryTopBar({
    super.key,
    required this.count,
    required this.ready,
    required this.sharing,
    required this.onClose,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          StoryTap(
            key: const Key('story-close'),
            label: 'Close',
            radius: 24,
            onTap: onClose,
            builder: (_) => Container(
              width: 48,
              height: 48,
              decoration: storyPill(context, radius: 24),
              child: Icon(Icons.close_rounded, color: scheme.onSurface),
            ),
          ),
          const Spacer(),
          StoryCharRing(count: count),
          const SizedBox(width: 12),
          StoryTap(
            key: const Key('share-story'),
            label: sharing ? 'Sharing your story' : 'Share story',
            radius: 26,
            scale: .9,
            onTap: ready ? onShare : null,
            builder: (pressed) =>
                _ShareButton(ready: ready, sharing: sharing, pressed: pressed),
          ),
        ],
      ),
    );
  }
}

class _ShareButton extends StatelessWidget {
  final bool ready, sharing, pressed;
  const _ShareButton({
    required this.ready,
    required this.sharing,
    required this.pressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = ready
        ? VibeColors.ink
        : scheme.onSurface.withValues(alpha: .38);
    return AnimatedContainer(
      key: Key(ready ? 'share-ready' : 'share-idle'),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        gradient: ready
            ? const LinearGradient(colors: [VibeColors.lime, Color(0xff5eead4)])
            : null,
        borderRadius: BorderRadius.circular(26),
        border: ready
            ? null
            : Border.all(color: scheme.outlineVariant, width: 1.5),
        boxShadow: ready
            ? [
                BoxShadow(
                  color: VibeColors.lime.withValues(alpha: pressed ? .65 : .3),
                  blurRadius: pressed ? 22 : 12,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sharing) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: VibeColors.ink,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            sharing ? 'Sharing…' : 'Share',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: ink,
            ),
          ),
          if (!sharing) ...[
            const SizedBox(width: 6),
            Icon(Icons.arrow_upward_rounded, size: 18, color: ink),
          ],
        ],
      ),
    );
  }
}
