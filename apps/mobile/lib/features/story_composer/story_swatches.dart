import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../shared/story_canvas.dart';
import 'story_tap.dart';

/// A scrolling row of chunky circular swatches. The chosen one grows, gets a ring and settles
/// with a tiny bounce (no bounce when the device asks for less motion).
class StorySwatchRow extends StatefulWidget {
  final String selected;
  final ValueChanged<String> onPick;
  const StorySwatchRow({
    super.key,
    required this.selected,
    required this.onPick,
  });
  @override
  State<StorySwatchRow> createState() => _StorySwatchRowState();
}

class _StorySwatchRowState extends State<StorySwatchRow> {
  static const _slot = 64.0;
  late final controller = ScrollController(
    initialScrollOffset: math.max(
      0,
      storyBackgrounds.indexWhere((b) => b.name == widget.selected) * _slot -
          90,
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    // Every swatch is built, so each one is reachable by screen readers and keyboards.
    Widget swatch(StoryBackground b) {
      final on = b.name == widget.selected;
      return Center(
        child: StoryTap(
          key: Key('swatch-${b.name}'),
          label: '${b.name} background',
          selected: on,
          radius: 32,
          scale: .9,
          onTap: () => widget.onPick(b.name),
          builder: (_) => SizedBox(
            width: _slot - 8,
            height: _slot - 8,
            child: Center(
              child: AnimatedScale(
                scale: on ? 1.14 : 1,
                duration: reduce
                    ? Duration.zero
                    : const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: reduce
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  width: 52,
                  height: 52,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: on ? scheme.onSurface : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: b.gradient,
                      border: Border.all(
                        color: scheme.outlineVariant,
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      key: const Key('swatches'),
      controller: controller,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [for (final b in storyBackgrounds) swatch(b)]),
    );
  }
}
