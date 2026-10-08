import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import 'widgets.dart';

class PreviewNotice extends StatelessWidget {
  const PreviewNotice({super.key});
  @override
  Widget build(BuildContext context) => VibePanel(
    padding: const EdgeInsets.all(16),
    child: const Row(
      children: [
        Icon(Icons.design_services_outlined, size: 20),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            'Design preview · sample content and temporary local interactions. Nothing is sent or published.',
            style: TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
      ],
    ),
  );
}

class SampleAvatar extends StatelessWidget {
  final double size;
  const SampleAvatar({super.key, this.size = 58});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: VibeColors.lilac,
      borderRadius: BorderRadius.circular(size * .32),
    ),
    child: Icon(Icons.face_rounded, color: VibeColors.ink, size: size * .58),
  );
}

class StoryTile extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const StoryTile({super.key, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$label story preview',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 142,
        padding: const EdgeInsets.all(18),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: VibeColors.lilac,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SampleAvatar(size: 54),
            Text(
              label,
              style: const TextStyle(
                color: VibeColors.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class MessageSurface extends StatelessWidget {
  final String text;
  final bool outgoing;
  final Color color;
  const MessageSurface({
    super.key,
    required this.text,
    required this.outgoing,
    this.color = VibeColors.lime,
  });
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 310),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: outgoing
            ? color
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(22),
          topRight: const Radius.circular(22),
          bottomLeft: Radius.circular(outgoing ? 22 : 8),
          bottomRight: Radius.circular(outgoing ? 8 : 22),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: outgoing
              ? (color == VibeColors.ink ? Colors.white : VibeColors.ink)
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ),
  );
}

class VoiceWaveform extends StatelessWidget {
  const VoiceWaveform({super.key});
  @override
  Widget build(BuildContext context) => VibePanel(
    color: VibeColors.mint,
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VibeTag('Voice layout / no audio', color: Colors.white),
        const SizedBox(height: 14),
        Row(
          children: [
            const Icon(
              Icons.play_circle_outline_rounded,
              color: VibeColors.ink,
              size: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 38,
                child: CustomPaint(painter: _WavePainter()),
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              '0:20',
              style: TextStyle(
                color: VibeColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = VibeColors.ink
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 28; i++) {
      final x = size.width * (i + .5) / 28;
      final h = [8.0, 15.0, 27.0, 19.0, 33.0, 12.0, 24.0][i % 7];
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => false;
}

void showCreationOrbit(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(duration: Duration(milliseconds: 220)),
  isScrollControlled: true,
  builder: (sheetContext) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VibeTag('Your next little idea', color: VibeColors.lilac),
          const SizedBox(height: 20),
          Text(
            'Make a little space.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          const Text(
            'Explore creation layouts. Publishing is not connected yet.',
          ),
          const SizedBox(height: 18),
          for (final item in [
            ('Post', 'create-post', Icons.notes_rounded),
            ('Story', 'create-story', Icons.photo_outlined),
            ('Vibe', 'create-vibe', Icons.auto_awesome_rounded),
            ('Poll', 'create-poll', Icons.poll_outlined),
            ('Question', 'create-question', Icons.question_mark_rounded),
            ('Event', 'create-event', Icons.event_outlined),
            ('Community', 'create-community', Icons.groups_outlined),
          ])
            ListTile(
              leading: Icon(item.$3),
              title: Text(item.$1),
              trailing: const Icon(Icons.arrow_outward_rounded),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.go('/design/${item.$2}');
              },
            ),
        ],
      ),
    ),
  ),
);
