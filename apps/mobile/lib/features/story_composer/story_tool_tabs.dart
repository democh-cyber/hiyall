import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/topics.dart';
import '../pulse.dart' show audienceLabels;
import 'story_audience_panel.dart';
import 'story_tap.dart';

enum StoryTool { colour, text, vibes, time, who, topic, voice }

/// The row of tabs under the canvas: colour, text, vibes, time and audience.
class StoryToolTabs extends StatelessWidget {
  final List<StoryTool> tools;
  final StoryTool tool;
  final int hours;
  final String audience;
  final ValueChanged<StoryTool> onOpen;

  /// The topic chosen for the story and whether a voice note is attached, shown on their tabs.
  final String? topic;
  final bool voiceAttached;
  const StoryToolTabs({
    super.key,
    required this.tools,
    required this.tool,
    required this.hours,
    required this.audience,
    required this.onOpen,
    this.topic,
    this.voiceAttached = false,
  });

  (String, String, String) _look(StoryTool t) => switch (t) {
    StoryTool.colour => ('🎨', 'Colour', 'Colour'),
    StoryTool.text => ('Aa', 'Text', 'Text style'),
    StoryTool.vibes => ('✨', 'Vibes', 'Vibes'),
    StoryTool.topic => (
      topic == null ? '#' : '✓',
      topic == null ? 'Topic' : topicLabel(topic!),
      topic == null ? 'Topic' : 'Topic: ${topicLabel(topic!)}',
    ),
    StoryTool.voice => (
      '🎙️',
      voiceAttached ? 'Voice ✓' : 'Voice',
      voiceAttached ? 'Voice note added' : 'Voice note',
    ),
    StoryTool.time => ('⏳', '${hours}h', 'Lasts $hours hours'),
    StoryTool.who => (
      storyAudienceEmoji[audience]!,
      audienceLabels[audience]!,
      'Who can see this: ${audienceLabels[audience]}',
    ),
  };

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final t in tools)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: StoryTap(
                  key: Key('tool-${t.name}'),
                  label: _look(t).$3,
                  selected: t == tool,
                  onTap: () => onOpen(t),
                  builder: (_) => _Tab(look: _look(t), on: t == tool),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _Tab extends StatelessWidget {
  final (String, String, String) look;
  final bool on;
  const _Tab({required this.look, required this.on});

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    alignment: Alignment.center,
    decoration: storyPill(context, on: on),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          look.$1,
          style: TextStyle(
            fontFamily: look.$1 == 'Aa' ? 'SpaceGrotesk' : null,
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: on
                ? VibeColors.ink
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 6),
        Text(look.$2, style: storyPillText(context, on: on)),
      ],
    ),
  );
}
