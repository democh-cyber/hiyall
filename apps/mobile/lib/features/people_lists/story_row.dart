import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../shared/story_canvas.dart';
import '../pulse.dart';
import '../settings.dart' show timeAgo;
import 'story_time.dart';

/// One of your active stories: a miniature of it, when it goes, who may see
/// it and how many did, with a delete button.
class StoryRow extends StatelessWidget {
  final Story story;
  final VoidCallback onOpen, onDelete;
  const StoryRow({
    super.key,
    required this.story,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final s = story;
    final scheme = Theme.of(context).colorScheme;
    final seen = s.viewCount ?? 0;
    return Padding(
      key: ValueKey('story-${s.storyId}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              key: Key('story-open-${s.storyId}'),
              borderRadius: BorderRadius.circular(14),
              onTap: () => onOpen(),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StoryPreview(story: s),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.body.isEmpty ? 'Photo story' : s.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${storyTimeLeft(s.expiresAt)} · posted ${timeAgo(s.createdAt)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                audienceIcon(s.audience),
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  audienceLabels[s.audience] ?? s.audience,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.visibility_outlined,
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                seen == 1
                                    ? 'Seen by 1'
                                    : 'Seen by ${s.viewsLabel}',
                                key: Key('story-views-${s.storyId}'),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: Key('story-delete-${s.storyId}'),
            tooltip: 'Delete story',
            onPressed: () => onDelete(),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }
}

/// The same canvas as the viewer, in miniature.
class _StoryPreview extends StatelessWidget {
  final Story story;
  const _StoryPreview({required this.story});

  @override
  Widget build(BuildContext context) {
    final s = story;
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 64,
        height: 88,
        child: StoryCanvas(
          decorative: true,
          background: s.background,
          textStyle: s.textStyle,
          body: s.body,
          photo: s.media != null && s.media!.thumbUrl.isNotEmpty
              ? Image.network(
                  s.media!.thumbUrl,
                  fit: BoxFit.cover,
                  cacheWidth: 192,
                  errorBuilder: (_, _, _) =>
                      ColoredBox(color: scheme.surfaceContainerHighest),
                )
              : null,
        ),
      ),
    );
  }
}
