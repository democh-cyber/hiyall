import 'package:flutter/material.dart';

import 'activity_art.dart';

class ActivityEmpty extends StatelessWidget {
  final double artHeight;
  final VoidCallback? onExplore;
  const ActivityEmpty({super.key, required this.artHeight, this.onExplore});
  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('activity-empty'),
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
    child: Column(
      children: [
        Text(
          'All caught up.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontSize: 26, height: 1.2),
        ),
        const SizedBox(height: 12),
        Text(
          'Nothing needs your attention right now.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        RepaintBoundary(
          child: ExcludeSemantics(
            child: SizedBox(
              width: 360,
              height: artHeight,
              child: CustomPaint(
                painter: QuietOrbitPainter(
                  Theme.of(context).brightness == Brightness.dark,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (onExplore != null)
          TextButton.icon(
            onPressed: onExplore,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            label: const Text(
              'Find your people',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            icon: const Icon(Icons.north_east_rounded, size: 16),
            iconAlignment: IconAlignment.end,
          ),
      ],
    ),
  );
}

class ActivitySkeleton extends StatelessWidget {
  const ActivitySkeleton({super.key});
  @override
  Widget build(BuildContext context) => SliverList.builder(
    itemCount: 5,
    itemBuilder: (context, index) {
      final color = Theme.of(context).colorScheme.onSurface
          .withValues(alpha: .07);
      Widget block(double width, double height) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
      );
      return Semantics(
        label: index == 0 ? 'Loading activity' : null,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: index.isEven ? .85 : .65,
                        child: block(double.infinity, 12),
                      ),
                      const SizedBox(height: 12),
                      block(72, 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class ActivityError extends StatelessWidget {
  final VoidCallback? onRetry;
  const ActivityError({super.key, this.onRetry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
    child: Column(
      children: [
        const Icon(Icons.cloud_off_outlined, size: 28),
        const SizedBox(height: 16),
        Text(
          'Something went sideways.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Your updates are taking a little longer.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (onRetry != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('Try again'),
            ),
          ),
      ],
    ),
  );
}
