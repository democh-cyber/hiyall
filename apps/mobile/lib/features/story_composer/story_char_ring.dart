import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'story_text_input.dart';

/// The remaining characters as a ring around the top bar: it fills as the story does, turns
/// amber near the limit and shows how many are left when it gets tight.
class StoryCharRing extends StatelessWidget {
  final int count;
  const StoryCharRing({super.key, required this.count});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final share = (count / storyMaxChars).clamp(0.0, 1.0);
    final left = storyMaxChars - count;
    final color = share >= 1
        ? scheme.error
        : share >= .85
        ? const Color(0xffffb020)
        : scheme.primary;
    return Semantics(
      label: '$count of $storyMaxChars characters used',
      excludeSemantics: true,
      child: SizedBox(
        key: const Key('story-counter'),
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size.square(34),
              painter: _RingPainter(share, scheme.outlineVariant, color),
            ),
            if (share >= .85)
              Text(
                '$left',
                key: const Key('story-counter-left'),
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: color,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color track, fill;
  const _RingPainter(this.value, this.track, this.fill);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect.deflate(2),
      0,
      math.pi * 2,
      false,
      paint..color = track,
    );
    if (value > 0) {
      canvas.drawArc(
        rect.deflate(2),
        -math.pi / 2,
        math.pi * 2 * value,
        false,
        paint..color = fill,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.track != track || old.fill != fill;
}
