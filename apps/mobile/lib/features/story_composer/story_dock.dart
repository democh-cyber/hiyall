import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'story_media_row.dart';
import 'story_tool_tabs.dart';

/// Everything under the canvas: the photo buttons, the tabs and the open panel. With the
/// keyboard up ([typing]) only the tabs are shown.
class StoryDock extends StatelessWidget {
  final bool typing, hasPhoto;
  final List<StoryTool> tools;
  final StoryTool tool;
  final int hours;
  final String audience;
  final Widget panel;
  final VoidCallback onGallery, onCamera, onChange, onRemove;
  final ValueChanged<StoryTool> onOpenTool;
  const StoryDock({
    super.key,
    required this.typing,
    required this.hasPhoto,
    required this.tools,
    required this.tool,
    required this.hours,
    required this.audience,
    required this.panel,
    required this.onGallery,
    required this.onCamera,
    required this.onChange,
    required this.onRemove,
    required this.onOpenTool,
  });

  @override
  Widget build(BuildContext context) {
    // With the keyboard up there is only room for the tabs; opening one closes the keyboard.
    // The controls grow with the reader's text size, up to 1.3x, so the canvas keeps its room.
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!typing)
            StoryMediaRow(
              hasPhoto: hasPhoto,
              onGallery: onGallery,
              onCamera: onCamera,
              onChange: onChange,
              onRemove: onRemove,
            ),
          StoryToolTabs(
            tools: tools,
            tool: tool,
            hours: hours,
            audience: audience,
            onOpen: onOpenTool,
          ),
          if (!typing)
            SizedBox(
              height: 88,
              child: AnimatedSwitcher(
                duration: VibeMotion.duration(context),
                child: KeyedSubtree(key: ValueKey(tool), child: panel),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
