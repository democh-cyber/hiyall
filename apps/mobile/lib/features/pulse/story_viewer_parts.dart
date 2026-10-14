import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../people_lists.dart' show storyTimeLeft;
import 'pulse_common.dart';

/// Keeps the white header readable on light photos and colours.
class StoryScrim extends StatelessWidget {
  const StoryScrim({super.key});

  @override
  Widget build(BuildContext context) => const PositionedDirectional(
    top: 0,
    start: 0,
    end: 0,
    height: 160,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x73000000), Color(0x00000000)],
          ),
        ),
      ),
    ),
  );
}

/// The progress bars and the author line with its options and close buttons.
class StoryHeader extends StatelessWidget {
  final StoryGroup group;
  final Story story;
  final int count, index;
  final Animation<double> timer;
  final VoidCallback onMenu, onClose;
  const StoryHeader({
    super.key,
    required this.group,
    required this.story,
    required this.count,
    required this.index,
    required this.timer,
    required this.onMenu,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final g = group;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 4, 0),
        child: Column(
          children: [
            Row(
              children: [
                for (var i = 0; i < count; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: AnimatedBuilder(
                          animation: timer,
                          builder: (_, _) => LinearProgressIndicator(
                            minHeight: 3,
                            value: i < index
                                ? 1
                                : (i == index ? timer.value : 0),
                            color: Colors.white,
                            backgroundColor: Colors.white30,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                PulseAvatar.of(g.author, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${g.mine ? 'Your story' : g.author.name}  ·  ${shortAgo(story.createdAt)}${g.mine ? '  ·  ${storyTimeLeft(story.expiresAt)}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(blurRadius: 6)],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Story options',
                  color: Colors.white,
                  icon: const Icon(Icons.more_horiz_rounded),
                  onPressed: onMenu,
                ),
                IconButton(
                  key: const Key('close-stories'),
                  tooltip: 'Close',
                  color: Colors.white,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: onClose,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Seen by N" button at the foot of your own story.
class StorySeenByButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const StorySeenByButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => PositionedDirectional(
    start: 0,
    end: 0,
    bottom: 24,
    child: SafeArea(
      child: Center(
        child: FilledButton.tonalIcon(
          key: const Key('story-viewers'),
          onPressed: onPressed,
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: Text('Seen by $label'),
        ),
      ),
    ),
  );
}

/// Delete (your own story) or report (someone else's).
class StoryMenuSheet extends StatelessWidget {
  final bool mine;
  const StoryMenuSheet({super.key, required this.mine});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mine)
          ListTile(
            key: const Key('delete-story'),
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('Delete story'),
            onTap: () => Navigator.pop(context, 'delete'),
          )
        else
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report story'),
            onTap: () => Navigator.pop(context, 'report'),
          ),
        const SizedBox(height: 8),
      ],
    ),
  );
}

/// Who has seen a story, from the answer to [viewers].
class StoryViewersSheet extends StatelessWidget {
  final Future<ApiPage<Map<String, dynamic>>> viewers;
  const StoryViewersSheet({super.key, required this.viewers});

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: .6,
    child: FutureBuilder(
      future: viewers,
      builder: (context, snap) {
        final list = snap.data?.items;
        if (snap.hasError) {
          return const Center(child: Text('Couldn’t load viewers.'));
        }
        if (list == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (list.isEmpty) return const Center(child: Text('No views yet.'));
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final v = list[i];
            return ListTile(
              leading: PulseAvatar.of(
                Person.fromJson(v['user'] as Map),
                radius: 18,
              ),
              title: Text(Person.fromJson(v['user'] as Map).name),
              subtitle: Text(shortAgo(DateTime.parse(v['since'] as String))),
            );
          },
        );
      },
    ),
  );
}
