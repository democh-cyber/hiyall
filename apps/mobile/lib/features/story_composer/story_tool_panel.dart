import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'story_audience_panel.dart';
import 'story_lifetime_panel.dart';
import 'story_swatches.dart';
import 'story_tap.dart';
import 'story_text_panel.dart';
import 'story_tool_tabs.dart';
import 'story_vibes_panel.dart';

/// The panel under the tabs for the open [tool].
class StoryToolPanel extends StatelessWidget {
  final StoryTool tool;
  final String background, textStyle, audience;
  final TextAlign align;
  final int hours;
  final ValueChanged<String> onBackground, onStyle, onAudience;
  final ValueChanged<TextAlign> onAlign;
  final ValueChanged<int> onHours;
  final void Function(String emoji, String word) onVibe;

  /// The topic picker and the voice recorder, built by the composer (they hold their own state).
  final Widget? topicPanel, voicePanel;
  const StoryToolPanel({
    super.key,
    required this.tool,
    required this.background,
    required this.textStyle,
    required this.audience,
    required this.align,
    required this.hours,
    required this.onBackground,
    required this.onStyle,
    required this.onAudience,
    required this.onAlign,
    required this.onHours,
    required this.onVibe,
    this.topicPanel,
    this.voicePanel,
  });

  @override
  Widget build(BuildContext context) => switch (tool) {
    StoryTool.colour => StorySwatchRow(
      selected: background,
      onPick: (name) {
        storyBuzz(HapticFeedback.selectionClick);
        onBackground(name);
      },
    ),
    StoryTool.text => StoryTextPanel(
      align: align,
      textStyle: textStyle,
      onAlign: onAlign,
      onStyle: onStyle,
    ),
    StoryTool.vibes => StoryVibesPanel(onVibe: onVibe),
    StoryTool.time => StoryLifetimePanel(hours: hours, onHours: onHours),
    StoryTool.who => StoryAudiencePanel(chosen: audience, onChoose: onAudience),
    StoryTool.topic => topicPanel ?? const SizedBox.shrink(),
    StoryTool.voice => voicePanel ?? const SizedBox.shrink(),
  };
}
