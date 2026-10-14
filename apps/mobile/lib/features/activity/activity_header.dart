import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

const _caption = 'Your people, moments and conversations.';

/// Heights the pinned header needs at the current width and text scale.
class ActivityHeaderMetrics {
  final double captionHeight, headingHeight, filterHeight;
  const ActivityHeaderMetrics({
    required this.captionHeight,
    required this.headingHeight,
    required this.filterHeight,
  });

  factory ActivityHeaderMetrics.measure(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final subtitle = TextPainter(
      text: const TextSpan(
        text: _caption,
        style: TextStyle(fontFamily: 'Manrope', fontSize: 13, height: 1.5),
      ),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout(maxWidth: width);
    final captionHeight = subtitle.height;
    subtitle.dispose();
    return ActivityHeaderMetrics(
      captionHeight: captionHeight,
      headingHeight: math.max(48.0, scaler.scale(28) * 1.2),
      filterHeight: math.max(48.0, scaler.scale(12) * 1.5 + 20),
    );
  }
}

class ActivityHeader extends SliverPersistentHeaderDelegate {
  final double captionHeight, headingHeight, filterHeight;
  final List<String> filters;
  final String selected;
  final ValueChanged<String> onSelect;
  final VoidCallback? onSettings, onMarkAllRead;
  const ActivityHeader({
    required this.captionHeight,
    required this.headingHeight,
    required this.filterHeight,
    required this.filters,
    required this.selected,
    required this.onSelect,
    this.onSettings,
    this.onMarkAllRead,
  });
  @override
  double get minExtent => 12 + headingHeight + filterHeight + 8;
  @override
  double get maxExtent => minExtent + captionHeight + 8;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final progress = (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0);
    return Container(
      height: maxExtent - shrinkOffset.clamp(0.0, maxExtent - minExtent),
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeadingRow(
            height: headingHeight,
            onMarkAllRead: onMarkAllRead,
            onSettings: onSettings,
          ),
          _CaptionReveal(captionHeight: captionHeight, progress: progress),
          SizedBox(
            height: filterHeight,
            child: _FilterTabs(
              filters: filters,
              selected: selected,
              onSelect: onSelect,
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(ActivityHeader old) =>
      captionHeight != old.captionHeight ||
      headingHeight != old.headingHeight ||
      filterHeight != old.filterHeight ||
      selected != old.selected ||
      filters != old.filters ||
      onSettings != old.onSettings ||
      onMarkAllRead != old.onMarkAllRead;
}

class _HeadingRow extends StatelessWidget {
  final double height;
  final VoidCallback? onSettings, onMarkAllRead;
  const _HeadingRow({
    required this.height,
    this.onSettings,
    this.onMarkAllRead,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Activity',
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 28,
                height: 1.2,
                fontWeight: FontWeight.w700,
                letterSpacing: -.8,
                color: scheme.onSurface,
              ),
            ),
          ),
          if (onMarkAllRead != null)
            IconButton(
              tooltip: 'Mark all as read',
              onPressed: onMarkAllRead,
              icon: const Icon(Icons.done_all_rounded, size: 22),
            ),
          if (onSettings != null)
            IconButton(
              tooltip: 'Activity visibility',
              onPressed: onSettings,
              icon: const Icon(Icons.tune_rounded, size: 22),
            ),
        ],
      ),
    );
  }
}

/// The subtitle that fades and collapses as the list scrolls under the header.
class _CaptionReveal extends StatelessWidget {
  final double captionHeight, progress;
  const _CaptionReveal({required this.captionHeight, required this.progress});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: (captionHeight + 8) * (1 - progress),
    child: ClipRect(
      child: OverflowBox(
        alignment: AlignmentDirectional.topStart,
        minHeight: captionHeight + 8,
        maxHeight: captionHeight + 8,
        child: Opacity(
          opacity: 1 - progress,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: Text(
                _caption,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FilterTabs extends StatelessWidget {
  final List<String> filters;
  final String selected;
  final ValueChanged<String> onSelect;
  const _FilterTabs({
    required this.filters,
    required this.selected,
    required this.onSelect,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: filters.length,
      separatorBuilder: (_, _) => const SizedBox(width: 24),
      itemBuilder: (context, index) {
        final active = filters[index] == selected;
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Semantics(
          selected: active,
          button: filters.length > 1,
          child: InkWell(
            onTap: filters.length > 1 ? () => onSelect(filters[index]) : null,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              constraints: const BoxConstraints(minWidth: 48),
              alignment: AlignmentDirectional.centerStart,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 12,
                      height: 1.5,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                      color: active
                          ? (dark ? VibeColors.lime : VibeColors.ink)
                          : scheme.onSurfaceVariant,
                    ),
                    child: Text(filters[index]),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: 16,
                    height: 3,
                    decoration: BoxDecoration(
                      color: active
                          ? (dark ? VibeColors.lime : const Color(0xff62802d))
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
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
}
