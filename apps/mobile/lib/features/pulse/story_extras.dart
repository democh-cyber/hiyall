import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/voice.dart' show ClipSource;
import 'topic_widgets.dart';
import 'translate_button.dart';
import 'voice_player.dart';

/// What a story carries beyond its picture or words, drawn over the story: its voice note, its topic and a
/// translate button for its words (on the phone; the translation shows here, in a small caption, so the story
/// itself is never redrawn). Nothing is shown for a plain story.
class StoryExtras extends StatelessWidget {
  final Story story;
  final String author;
  const StoryExtras({super.key, required this.story, required this.author});

  @override
  Widget build(BuildContext context) {
    final voice = story.voice;
    final hasText = story.body.trim().isNotEmpty;
    if (voice == null && story.topic == null && !hasText) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (voice != null)
          VoicePlayerBar(
            key: ValueKey('story-voice-${story.storyId}'),
            id: voice.mediaId,
            source: ClipSource.url(voice.url),
            duration: voice.duration,
            label: 'Voice note from $author',
            onDark: true,
          ),
        if (hasText)
          TranslateScope(
            key: ValueKey('story-translate-${story.storyId}'),
            id: story.storyId,
            text: story.body,
            onDark: true,
            builder: (context, shown, button) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The translation appears only once asked for: [shown] is the original until then.
                if (shown != story.body)
                  Container(
                    key: Key('story-translation-${story.storyId}'),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      shown,
                      style: const TextStyle(color: Colors.white, height: 1.35),
                    ),
                  ),
                ?button,
              ],
            ),
          ),
        if (story.topic != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TopicLabel(
                story.topic!,
                key: Key('story-topic-${story.storyId}'),
                onDark: true,
              ),
            ),
          ),
      ],
    );
  }
}
