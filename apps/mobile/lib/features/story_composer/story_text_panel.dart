import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/story_draft.dart';
import '../../core/theme.dart';
import '../../shared/story_canvas.dart';
import 'story_tap.dart';

/// Alignment and text style.
class StoryTextPanel extends StatelessWidget {
  final TextAlign align;
  final String textStyle;
  final ValueChanged<TextAlign> onAlign;
  final ValueChanged<String> onStyle;
  const StoryTextPanel({
    super.key,
    required this.align,
    required this.textStyle,
    required this.onAlign,
    required this.onStyle,
  });

  @override
  Widget build(BuildContext context) => StoryScrollRow(
    children: [
      // RTL: physical. These pick which side the words sit on, and are saved by name.
      _AlignButton(
        target: TextAlign.left,
        icon: Icons.format_align_left_rounded,
        label: 'Align left',
        current: align,
        onAlign: onAlign,
      ),
      _AlignButton(
        target: TextAlign.center,
        icon: Icons.format_align_center_rounded,
        label: 'Align centre',
        current: align,
        onAlign: onAlign,
      ),
      _AlignButton(
        target: TextAlign.right,
        icon: Icons.format_align_right_rounded,
        label: 'Align right',
        current: align,
        onAlign: onAlign,
      ),
      const SizedBox(width: 8),
      for (final spec in storyTextStyles)
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: StoryTap(
            key: Key('style-${spec.name}'),
            label: '${spec.label} text style',
            selected: textStyle == spec.name,
            onTap: () {
              storyBuzz(HapticFeedback.selectionClick);
              onStyle(spec.name);
            },
            builder: (_) => _StyleChip(spec: spec, on: textStyle == spec.name),
          ),
        ),
    ],
  );
}

class _AlignButton extends StatelessWidget {
  final TextAlign target, current;
  final IconData icon;
  final String label;
  final ValueChanged<TextAlign> onAlign;
  const _AlignButton({
    required this.target,
    required this.icon,
    required this.label,
    required this.current,
    required this.onAlign,
  });

  @override
  Widget build(BuildContext context) {
    final on = current == target;
    return StoryTap(
      key: Key('align-${StoryDraft.nameOf(target)}'),
      label: label,
      selected: on,
      radius: 24,
      onTap: () {
        storyBuzz(HapticFeedback.selectionClick);
        onAlign(target);
      },
      builder: (_) => Container(
        width: 44,
        height: 44,
        decoration: on ? storyPill(context, on: true, radius: 22) : null,
        child: Icon(
          icon,
          color: on ? VibeColors.ink : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _StyleChip extends StatelessWidget {
  final StoryTextSpec spec;
  final bool on;
  const _StyleChip({required this.spec, required this.on});

  @override
  Widget build(BuildContext context) => Container(
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    alignment: Alignment.center,
    decoration: storyPill(context, on: on),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          storyDisplayText('Aa', spec),
          style: spec.style(
            ink: on ? VibeColors.ink : Theme.of(context).colorScheme.onSurface,
            px: 20,
            k: 1,
          ),
        ),
        const SizedBox(width: 8),
        Text(spec.label, style: storyPillText(context, on: on)),
      ],
    ),
  );
}
