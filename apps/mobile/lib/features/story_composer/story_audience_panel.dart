import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../pulse.dart' show audienceLabels;
import 'story_tap.dart';

const storyAudienceEmoji = {'public': '🌍', 'followers': '👥', 'friends': '💚'};

const _audienceHints = {
  'public': 'Anyone on Hiyall can watch',
  'followers': 'Only your followers',
  'friends': 'Only your friends',
};

/// Who can see the story.
class StoryAudiencePanel extends StatelessWidget {
  final String chosen;
  final ValueChanged<String> onChoose;
  const StoryAudiencePanel({
    super.key,
    required this.chosen,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = VibeMotion.duration(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                for (final e in audienceLabels.entries)
                  Expanded(
                    child: StoryTap(
                      key: Key('audience-${e.key}'),
                      label: e.value,
                      selected: chosen == e.key,
                      radius: 100,
                      onTap: () {
                        storyBuzz(HapticFeedback.selectionClick);
                        onChoose(e.key);
                      },
                      builder: (_) => AnimatedContainer(
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: chosen == e.key
                              ? VibeColors.lime
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${storyAudienceEmoji[e.key]} ${e.value}',
                            style: storyPillText(context, on: chosen == e.key),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        AnimatedSwitcher(
          duration: duration,
          child: Text(
            _audienceHints[chosen]!,
            key: ValueKey(chosen),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.2,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
