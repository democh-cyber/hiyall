import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pulse_tabs.dart';
import '../../core/theme.dart';
import '../../core/topics.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';

/// One topic as a pill: an icon and its name, or "All" ([topic] null). At least 48 high to tap, whatever the
/// text size.
class TopicChip extends StatelessWidget {
  final String? topic;
  final bool selected;
  final VoidCallback onTap;
  const TopicChip({
    super.key,
    required this.topic,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final label = topic == null ? 'All' : topicLabel(topic!);
    final fg = selected ? t.onLime : t.text;
    return PressScale(
      minHeight: 48,
      selected: selected,
      semanticLabel: label,
      onTap: onTap,
      child: Align(
        widthFactor: 1,
        child: AnimatedContainer(
          duration: VibeMotion.duration(context),
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? t.lime : t.elevated,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: selected ? t.lime : t.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (topic != null) ...[
                Icon(topicIcon(topic!), size: 17, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 14,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The row of topics above a feed: "All" first, then each topic. Choosing one narrows the posts and stories
/// of the tab [mode] to it (remembered in memory for that tab only).
class TopicChipsRow extends ConsumerWidget {
  final String mode;
  const TopicChipsRow({super.key, required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(topicListProvider).asData?.value ?? topicNames;
    final chosen = ref.watch(pulseTopicProvider(mode));
    final notifier = ref.read(pulseTopicProvider(mode).notifier);
    // A topic a newer server added that is gone now is no longer chosen.
    final shown = chosen == null || names.contains(chosen)
        ? names
        : [...names, chosen];
    return SizedBox(
      height: 52,
      child: ListView(
        key: Key('topic-chips-$mode'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: TopicChip(
              key: const Key('topic-chip-all'),
              topic: null,
              selected: chosen == null,
              onTap: () => notifier.set(null),
            ),
          ),
          for (final name in shown)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: TopicChip(
                key: Key('topic-chip-$name'),
                topic: name,
                selected: chosen == name,
                onTap: () => notifier.set(chosen == name ? null : name),
              ),
            ),
        ],
      ),
    );
  }
}

/// Picking at most one topic for a post or a story: tap one, tap it again to clear it.
class TopicPicker extends ConsumerWidget {
  final String? selected;
  final ValueChanged<String?> onChanged;

  /// One scrolling row (for the story composer's panel) instead of wrapping lines.
  final bool singleRow;
  const TopicPicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.singleRow = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(topicListProvider).asData?.value ?? topicNames;
    final chips = [
      for (final name in names)
        TopicChip(
          key: Key('topic-pick-$name'),
          topic: name,
          selected: selected == name,
          onTap: () => onChanged(selected == name ? null : name),
        ),
    ];
    if (singleRow) {
      return SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: chips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => chips[i],
        ),
      );
    }
    return Wrap(spacing: 8, runSpacing: 0, children: chips);
  }
}

/// A small topic label for a post or a story: the icon and the name. A name this app does not know shows as
/// plain text.
class TopicLabel extends StatelessWidget {
  final String topic;

  /// White on a dark picture (the story viewer) instead of the theme's colours.
  final bool onDark;
  const TopicLabel(this.topic, {super.key, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final color = onDark ? Colors.white : t.textSecondary;
    return Semantics(
      label: 'Topic: ${topicLabel(topic)}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(topicIcon(topic), size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              topicLabel(topic),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
