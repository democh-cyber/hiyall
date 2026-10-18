import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/feed_state.dart';
import '../../core/user_error.dart';
import '../../shared/story_canvas.dart';
import '../safety.dart';
import 'pulse_actions.dart';
import 'pulse_common.dart';
import 'story_viewer_parts.dart';
import 'story_extras.dart';

/// Full-screen stories: tap right for next, left for previous, hold to pause.
class StoryViewer extends ConsumerStatefulWidget {
  final List<StoryGroup> groups;
  final int start;
  const StoryViewer({super.key, required this.groups, required this.start});
  @override
  ConsumerState<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends ConsumerState<StoryViewer>
    with SingleTickerProviderStateMixin {
  static const shownFor = Duration(seconds: 5);
  late int group = widget.start;
  late int index = _firstUnseen(widget.groups[widget.start]);
  late final timer = AnimationController(vsync: this, duration: shownFor)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) next();
    });
  final viewed = <String>{};
  final removed = <String>{};

  /// Set once the viewer starts closing. The timer finishing, a tap and a
  /// swipe can all ask to close in the same frame; only the first pops.
  bool closing = false;

  PulseActions get actions => ref.read(pulseActionsProvider);

  static int _firstUnseen(StoryGroup g) {
    final i = g.stories.indexWhere((s) => !s.seen);
    return g.mine || i < 0 ? 0 : i;
  }

  List<Story> get stories => [
    for (final s in widget.groups[group].stories)
      if (!removed.contains(s.storyId)) s,
  ];

  @override
  void initState() {
    super.initState();
    show();
  }

  @override
  void dispose() {
    timer.dispose();
    super.dispose();
  }

  void show() {
    if (closing) return;
    final list = stories;
    if (list.isEmpty) {
      next();
      return;
    }
    index = index.clamp(0, list.length - 1);
    final story = list[index];
    final g = widget.groups[group];
    if (!g.mine && !story.seen && viewed.add(story.storyId)) {
      if (actions.hasSession) {
        actions.viewStory(story.storyId).catchError((_) {});
      }
    }
    // A story with a voice note stays up for as long as the note plays (and a moment more).
    final voice = story.voice;
    timer.duration = voice == null
        ? shownFor
        : voice.duration + const Duration(seconds: 1) > shownFor
        ? voice.duration + const Duration(seconds: 1)
        : shownFor;
    timer.forward(from: 0);
  }

  void close() {
    if (closing || !mounted) return;
    closing = true;
    timer.stop();
    ref.invalidate(storyTrayProvider);
    Navigator.of(context).pop();
  }

  void next() {
    if (closing) return;
    if (index + 1 < stories.length) {
      setState(() => index++);
    } else if (group + 1 < widget.groups.length) {
      setState(() {
        group++;
        index = _firstUnseen(widget.groups[group]);
      });
    } else {
      close();
      return;
    }
    show();
  }

  void previous() {
    if (closing) return;
    if (index > 0) {
      setState(() => index--);
    } else if (group > 0) {
      setState(() {
        group--;
        index = 0;
      });
    }
    show();
  }

  Future<void> menu(Story story, StoryGroup g) async {
    timer.stop();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => StoryMenuSheet(mine: g.mine),
    );
    if (!mounted) return;
    if (choice == 'delete' && actions.hasSession) {
      try {
        await actions.deleteStory(story.storyId);
        if (!mounted) return;
        setState(() => removed.add(story.storyId));
        show();
        return;
      } catch (e) {
        if (mounted) showFailure(context, e);
      }
    } else if (choice == 'report') {
      await showReportSheet(
        context,
        ref,
        targetType: 'story',
        targetId: story.storyId,
        name: g.author.name,
      );
    }
    if (mounted && !closing) timer.forward();
  }

  Future<void> viewers(Story story) async {
    timer.stop();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          StoryViewersSheet(viewers: actions.storyViewers(story.storyId)),
    );
    if (mounted && !closing) timer.forward();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.groups[group];
    final list = stories;
    if (list.isEmpty) return const ColoredBox(color: Colors.black);
    final story = list[index.clamp(0, list.length - 1)];
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // RTL: physical. The left third always goes back and the rest forward,
        // like the screen halves of any story viewer.
        onTapUp: (d) =>
            d.globalPosition.dx < MediaQuery.sizeOf(context).width / 3
            ? previous()
            : next(),
        onLongPressStart: (_) => timer.stop(),
        onLongPressEnd: (_) {
          if (!closing) timer.forward();
        },
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) close();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The same canvas the composer and My stories draw, so a story looks as it was made.
            StoryCanvas(
              key: ValueKey(story.storyId),
              background: story.background,
              textStyle: story.textStyle,
              body: story.body,
              photo: story.media == null ? null : PostPhoto(story.media!),
            ),
            const StoryScrim(),
            StoryHeader(
              group: g,
              story: story,
              count: list.length,
              index: index,
              timer: timer,
              onMenu: () => menu(story, g),
              onClose: close,
            ),
            // The voice note, the topic and a translate button sit above the seen-by line, clear of the tap areas.
            Positioned.directional(
              textDirection: Directionality.of(context),
              start: 16,
              end: 16,
              bottom: g.mine ? 72 : 24,
              child: StoryExtras(story: story, author: g.author.name),
            ),
            if (g.mine)
              StorySeenByButton(
                label: story.viewsLabel,
                onPressed: () => viewers(story),
              ),
          ],
        ),
      ),
    );
  }
}
