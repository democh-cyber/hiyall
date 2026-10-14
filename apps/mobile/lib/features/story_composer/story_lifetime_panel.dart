import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/story_draft.dart';
import '../../core/theme.dart';
import 'story_tap.dart';

/// How long the story lasts.
class StoryLifetimePanel extends StatelessWidget {
  final int hours;
  final ValueChanged<int> onHours;
  const StoryLifetimePanel({
    super.key,
    required this.hours,
    required this.onHours,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in storyLifetimeChoices)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: StoryTap(
                  key: Key('hours-$h'),
                  label: 'Lasts $h hours',
                  selected: hours == h,
                  onTap: () {
                    storyBuzz(HapticFeedback.selectionClick);
                    onHours(h);
                  },
                  builder: (_) => _HoursChip(hours: h, on: hours == h),
                ),
              ),
          ],
        ),
      ),
      Text(
        'Gone $hours hours after you share',
        key: const Key('hours-hint'),
        style: TextStyle(
          fontSize: 12.5,
          height: 1.2,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class _HoursChip extends StatelessWidget {
  final int hours;
  final bool on;
  const _HoursChip({required this.hours, required this.on});

  @override
  Widget build(BuildContext context) => Container(
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    alignment: Alignment.center,
    decoration: storyPill(context, on: on),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule_rounded,
          size: 16,
          color: on
              ? VibeColors.ink
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text('${hours}h', style: storyPillText(context, on: on, size: 15)),
      ],
    ),
  );
}
