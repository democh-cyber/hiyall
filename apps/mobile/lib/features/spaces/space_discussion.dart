import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../shared/person_link.dart';
import '../../shared/segmented.dart';
import '../settings.dart' show timeAgo;
import 'space_parts.dart';

/// Title, composer (when allowed) and the empty-state line above the entries.
class SpaceDiscussionHeader extends StatelessWidget {
  final SocialSpace space;
  final TextEditingController text;
  final bool busy, loading, hasEntries;
  final VoidCallback onPost;
  const SpaceDiscussionHeader({
    super.key,
    required this.space,
    required this.text,
    required this.busy,
    required this.loading,
    required this.hasEntries,
    required this.onPost,
  });

  @override
  Widget build(BuildContext context) {
    final x = space;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shared discussion',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text('Talk, share and meet people inside this circle.', style: muted),
        const SizedBox(height: 16),
        if (x.canDiscuss) ...[
          TextField(
            key: const Key('space-entry'),
            controller: text,
            maxLength: 2000,
            maxLines: 4,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            buildCounter:
                (_, {required currentLength, required isFocused, maxLength}) =>
                    currentLength < 1800
                    ? null
                    : Text('$currentLength / $maxLength'),
            decoration: InputDecoration(
              hintText: 'What’s on your mind?',
              suffixIcon: Padding(
                padding: const EdgeInsets.all(6),
                child: IconButton.filled(
                  key: const Key('send-space-entry'),
                  tooltip: 'Post',
                  onPressed: busy || loading ? null : onPost,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 14, color: muted.color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Seen by members and Hiyall. Keep private talk in encrypted chat.',
                  style: muted.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ] else
          const SpaceInfoLine(
            Icons.lock_clock_outlined,
            'This discussion is read-only outside its scheduled time or while closed.',
          ),
        const SizedBox(height: 18),
        if (!hasEntries && !loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                x.canDiscuss
                    ? 'Nothing here yet. Start the conversation.'
                    : 'No one shared anything while this was open.',
                style: muted,
              ),
            ),
          ),
      ],
    );
  }
}

/// One post in the discussion: author, body, age and a delete/report menu.
class SpaceEntryTile extends StatelessWidget {
  final SpaceEntry entry;

  /// Whether the signed-in person wrote it (they cannot report themselves).
  final bool mine;
  final VoidCallback onDelete, onReport;
  const SpaceEntryTile({
    super.key,
    required this.entry,
    required this.mine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final scheme = Theme.of(context).colorScheme;
    return EntranceFade(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => openPerson(context, e.author.userId),
              child: SpacePersonAvatar(e.author),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: InkWell(
                            onTap: () => openPerson(context, e.author.userId),
                            child: Text(
                              e.author.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (e.canDelete || !mine)
                        SizedBox(
                          width: 32,
                          height: 28,
                          child: PopupMenuButton<String>(
                            tooltip: 'More',
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            icon: Icon(
                              Icons.more_vert,
                              color: scheme.onSurfaceVariant,
                            ),
                            onSelected: (v) =>
                                v == 'delete' ? onDelete() : onReport(),
                            itemBuilder: (_) => [
                              if (e.canDelete)
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              if (!mine)
                                const PopupMenuItem(
                                  value: 'report',
                                  child: Text('Report'),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    e.body,
                    style: const TextStyle(fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    timeAgo(e.createdAt),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
