import 'package:flutter/material.dart';

import 'story_tap.dart';

const storyVibes = [
  ('😴', 'sleepy'),
  ('🔥', 'on fire'),
  ('🎧', 'vibing'),
  ('🌧️', 'gloomy'),
  ('📍', 'out and about'),
  ('🥳', 'celebrating'),
  ('😎', 'chilling'),
  ('📚', 'studying'),
  ('🍕', 'snack time'),
  ('🎮', 'gaming'),
  ('🥹', 'feeling things'),
  ('✨', 'main character'),
];

/// Quick phrases that are added after the words.
class StoryVibesPanel extends StatelessWidget {
  final void Function(String emoji, String word) onVibe;
  const StoryVibesPanel({super.key, required this.onVibe});

  @override
  Widget build(BuildContext context) => StoryScrollRow(
    children: [
      for (final (emoji, word) in storyVibes)
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: StoryTap(
            key: Key('vibe-$word'),
            label: '$emoji $word',
            onTap: () => onVibe(emoji, word),
            builder: (_) => Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: storyPill(context),
              child: Text('$emoji $word', style: storyPillText(context)),
            ),
          ),
        ),
    ],
  );
}
