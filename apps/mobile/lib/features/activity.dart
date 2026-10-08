import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../shared/widgets.dart';

// Presentation groups use only Notification.type values in the existing
// contract. They are not new categories or fields in notification records.
const _groups = {
  'like': 'Social',
  'comment': 'Social',
  'follow': 'Connections',
  'friend_request': 'Connections',
  'message': 'Messages',
  'message_request': 'Messages',
  'security': 'System',
  'moderation': 'System',
};

/// A view of existing Notification JSON, with no fetching or mutation logic.
/// Callbacks belong to the caller; absent handlers never create pretend actions.
class ActivityView extends StatefulWidget {
  final AsyncValue<List<Map<String, dynamic>>> activity;
  final VoidCallback? onExplore, onSettings, onRetry;
  final Future<void> Function()? onRefresh;
  final VoidCallback? Function(Map<String, dynamic>)? openNotification;
  final VoidCallback? Function(Map<String, dynamic>)? markRead, dismiss;
  final ImageProvider? Function(Map<String, dynamic>)? avatarImage;

  /// Inline controls under a row, such as Accept/Decline on a request.
  final Widget? Function(Map<String, dynamic>)? actions;

  /// Called near the end of the list to fetch the next page.
  final VoidCallback? onLoadMore;
  final bool loadingMore;
  final VoidCallback? onMarkAllRead;
  final DateTime? now;

  const ActivityView({
    super.key,
    required this.activity,
    this.onExplore,
    this.onSettings,
    this.onRetry,
    this.onRefresh,
    this.openNotification,
    this.markRead,
    this.dismiss,
    this.avatarImage,
    this.actions,
    this.onLoadMore,
    this.loadingMore = false,
    this.onMarkAllRead,
    this.now,
  });

  @override
  State<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<ActivityView> {
  String selected = 'All';
  RefreshIndicatorStatus? refreshStatus;

  @override
  Widget build(BuildContext context) {
    final items =
        widget.activity.asData?.value ?? const <Map<String, dynamic>>[];
    final groups = items.map((item) => _groups[item['type']]).toSet();
    final filters = [
      'All',
      for (final group in ['Social', 'Connections', 'Messages', 'System'])
        if (groups.contains(group)) group,
    ];
    final filter = filters.contains(selected) ? selected : 'All';
    final filtered = filter == 'All'
        ? items
        : items
              .where((item) => _groups[item['type']] == filter)
              .toList(growable: false);
    final now = widget.now ?? DateTime.now();
    final scheme = Theme.of(context).colorScheme;

    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth - 48;
              final scaler = MediaQuery.textScalerOf(context);
              final subtitle = TextPainter(
                text: const TextSpan(
                  text: 'Your people, moments and conversations.',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                textDirection: Directionality.of(context),
                textScaler: scaler,
              )..layout(maxWidth: width);
              final captionHeight = subtitle.height;
              subtitle.dispose();
              final headingHeight = math.max(48.0, scaler.scale(28) * 1.2);
              final filterHeight = math.max(48.0, scaler.scale(12) * 1.5 + 20);
              final scroll = CustomScrollView(
                physics: widget.onRefresh == null
                    ? null
                    : const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _ActivityHeader(
                      captionHeight: captionHeight,
                      headingHeight: headingHeight,
                      filterHeight: filterHeight,
                      filters: filters,
                      selected: filter,
                      onSelect: (value) => setState(() => selected = value),
                      onSettings: widget.onSettings,
                      onMarkAllRead: widget.onMarkAllRead,
                    ),
                  ),
                  ...widget.activity.when(
                    skipLoadingOnRefresh: false,
                    loading: () => [
                      const SliverPadding(
                        padding: EdgeInsets.fromLTRB(24, 24, 24, 32),
                        sliver: _ActivitySkeleton(),
                      ),
                    ],
                    error: (_, _) => [
                      SliverToBoxAdapter(
                        child: _ActivityError(onRetry: widget.onRetry),
                      ),
                    ],
                    data: (_) => filtered.isEmpty
                        ? [
                            SliverToBoxAdapter(
                              child: _ActivityEmpty(
                                artHeight: (constraints.maxHeight * .3).clamp(
                                  160.0,
                                  280.0,
                                ),
                                onExplore: widget.onExplore,
                              ),
                            ),
                          ]
                        : [
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                16,
                                24,
                                32,
                              ),
                              sliver: SliverList.builder(
                                itemCount: filtered.length,
                                itemBuilder: (context, index) {
                                  if (index >= filtered.length - 3) {
                                    // Ask for the next page before the end is reached.
                                    final more = widget.onLoadMore;
                                    if (more != null && !widget.loadingMore) {
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) => more());
                                    }
                                  }
                                  final item = filtered[index];
                                  final day = _dayLabel(item, now, context);
                                  final showDay =
                                      index == 0 ||
                                      day !=
                                          _dayLabel(
                                            filtered[index - 1],
                                            now,
                                            context,
                                          );
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (showDay && day.isNotEmpty)
                                        Padding(
                                          padding: EdgeInsets.only(
                                            top: index == 0 ? 8 : 24,
                                            bottom: 12,
                                          ),
                                          child: Text(
                                            day.toUpperCase(),
                                            style: TextStyle(
                                              fontSize: 10,
                                              letterSpacing: 1.5,
                                              fontWeight: FontWeight.w800,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      _ActivityRow(
                                        key: ValueKey(item['notificationId']),
                                        item: item,
                                        now: now,
                                        onOpen: widget.openNotification?.call(
                                          item,
                                        ),
                                        onMarkRead: widget.markRead?.call(item),
                                        onDismiss: widget.dismiss?.call(item),
                                        avatarImage: widget.avatarImage,
                                        actions: widget.actions?.call(item),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                  ),
                ],
              );
              if (widget.onRefresh == null) return scroll;
              return Stack(
                children: [
                  RefreshIndicator.noSpinner(
                    onRefresh: widget.onRefresh!,
                    onStatusChange: (value) {
                      if (mounted) setState(() => refreshStatus = value);
                    },
                    child: scroll,
                  ),
                  if (refreshStatus != null)
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: _RefreshOrbit(
                            loading:
                                refreshStatus == RefreshIndicatorStatus.refresh,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ActivityHeader extends SliverPersistentHeaderDelegate {
  final double captionHeight, headingHeight, filterHeight;
  final List<String> filters;
  final String selected;
  final ValueChanged<String> onSelect;
  final VoidCallback? onSettings, onMarkAllRead;
  const _ActivityHeader({
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
    final scheme = Theme.of(context).colorScheme;
    final progress = (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0);
    return Container(
      height: maxExtent - shrinkOffset.clamp(0.0, maxExtent - minExtent),
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: headingHeight,
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
          ),
          SizedBox(
            height: (captionHeight + 8) * (1 - progress),
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minHeight: captionHeight + 8,
                maxHeight: captionHeight + 8,
                child: Opacity(
                  opacity: 1 - progress,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Text(
                        'Your people, moments and conversations.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: filterHeight,
            child: ListView.separated(
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
                    onTap: filters.length > 1
                        ? () => onSelect(filters[index])
                        : null,
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
                              fontWeight: active
                                  ? FontWeight.w800
                                  : FontWeight.w500,
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
                                  ? (dark
                                        ? VibeColors.lime
                                        : const Color(0xff62802d))
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
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_ActivityHeader old) =>
      captionHeight != old.captionHeight ||
      headingHeight != old.headingHeight ||
      filterHeight != old.filterHeight ||
      selected != old.selected ||
      filters != old.filters ||
      onSettings != old.onSettings ||
      onMarkAllRead != old.onMarkAllRead;
}

class _ActivityEmpty extends StatelessWidget {
  final double artHeight;
  final VoidCallback? onExplore;
  const _ActivityEmpty({required this.artHeight, this.onExplore});
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
                painter: _QuietOrbitPainter(
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

DateTime? _received(Map<String, dynamic> item) =>
    DateTime.tryParse(item['createdAt'] as String? ?? '')?.toLocal();
String _dayLabel(
  Map<String, dynamic> item,
  DateTime now,
  BuildContext context,
) {
  final date = _received(item);
  if (date == null) return '';
  if (DateUtils.isSameDay(date, now)) {
    return 'Today';
  }
  if (DateUtils.isSameDay(date, DateTime(now.year, now.month, now.day - 1))) {
    return 'Yesterday';
  }
  return MaterialLocalizations.of(context).formatMediumDate(date);
}

String _timeLabel(
  Map<String, dynamic> item,
  DateTime now,
  BuildContext context,
) {
  final date = _received(item);
  if (date == null) return '';
  final elapsed = now.difference(date);
  if (elapsed.inMinutes < 1) {
    return 'Just now';
  }
  if (elapsed.inHours < 1) {
    return '${elapsed.inMinutes}m';
  }
  if (elapsed.inDays < 1) {
    return '${elapsed.inHours}h';
  }
  if (elapsed.inDays < 7) {
    return '${elapsed.inDays}d';
  }
  return MaterialLocalizations.of(context).formatShortDate(date);
}

class _ActivityRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final DateTime now;
  final VoidCallback? onOpen, onMarkRead, onDismiss;
  final ImageProvider? Function(Map<String, dynamic>)? avatarImage;
  final Widget? actions;
  const _ActivityRow({
    super.key,
    required this.item,
    required this.now,
    this.onOpen,
    this.onMarkRead,
    this.onDismiss,
    this.avatarImage,
    this.actions,
  });
  @override
  Widget build(BuildContext context) {
    final unread = item['readAt'] == null;
    final scheme = Theme.of(context).colorScheme;
    final text = item['text'] as String? ?? '';
    final actors = (item['actors'] as List? ?? []).cast<Map<String, dynamic>>();
    final count = item['count'] as int? ?? 1;
    final timestamp = _timeLabel(item, now, context);
    final type = item['type'] as String? ?? '';
    final (icon, tint) = switch (type) {
      'like' => (Icons.favorite_border_rounded, VibeColors.pink),
      'comment' => (Icons.chat_bubble_outline_rounded, VibeColors.lilac),
      'follow' ||
      'friend_request' => (Icons.person_add_alt_1_outlined, VibeColors.lime),
      'message' || 'message_request' => (Icons.forum_outlined, VibeColors.mint),
      'security' => (Icons.shield_outlined, VibeColors.peach),
      'moderation' => (Icons.info_outline_rounded, VibeColors.lilac),
      _ => (Icons.auto_awesome_outlined, VibeColors.lilac),
    };
    return Semantics(
      container: true,
      label: unread ? 'Unread activity' : 'Read activity',
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 20, right: 8),
                child: SizedBox(
                  width: 6,
                  height: 6,
                  child: unread
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            color: VibeColors.lime,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
              ),
              SizedBox(
                width: actors.length > 1 ? 60 : 48,
                height: 52,
                child: Stack(
                  children: [
                    if (actors.isEmpty)
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(icon, size: 20, color: scheme.onSurface),
                      ),
                    for (var i = math.min(actors.length, 2) - 1; i >= 0; i--)
                      Positioned(
                        left: i * 12,
                        top: i * 4,
                        child: _ActorAvatar(
                          actor: actors[i],
                          tint: tint,
                          image: avatarImage?.call(actors[i]),
                        ),
                      ),
                    if (actors.isNotEmpty)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: tint,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                          child: Icon(icon, size: 11, color: VibeColors.ink),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (timestamp.isNotEmpty)
                          Text(
                            timestamp,
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (count > 1)
                          Text(
                            '$count updates',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (unread)
                          Text(
                            'New',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    if (actions != null) ...[
                      const SizedBox(height: 12),
                      actions!,
                    ],
                  ],
                ),
              ),
              if ((unread && onMarkRead != null) || onDismiss != null)
                PopupMenuButton<String>(
                  tooltip: 'Activity actions',
                  iconSize: 18,
                  onSelected: (action) {
                    if (action == 'read') {
                      onMarkRead?.call();
                    } else {
                      onDismiss?.call();
                    }
                  },
                  itemBuilder: (_) => [
                    if (unread && onMarkRead != null)
                      const PopupMenuItem(
                        value: 'read',
                        child: Text('Mark as read'),
                      ),
                    if (onDismiss != null)
                      const PopupMenuItem(
                        value: 'dismiss',
                        child: Text('Dismiss'),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActorAvatar extends StatelessWidget {
  final Map<String, dynamic> actor;
  final Color tint;
  final ImageProvider? image;
  const _ActorAvatar({required this.actor, required this.tint, this.image});
  @override
  Widget build(BuildContext context) {
    final name = actor['displayName'] as String? ?? '';
    final initial = name.trim().isEmpty
        ? ''
        : name.trim().characters.first.toUpperCase();
    final fallback = ColoredBox(
      color: tint,
      child: Center(
        child: Text(
          initial,
          textScaler: TextScaler.noScaling,
          style: const TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: VibeColors.ink,
          ),
        ),
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).scaffoldBackgroundColor,
            width: 2,
          ),
        ),
        child: ClipOval(
          child: image == null
              ? fallback
              : Image(
                  image: ResizeImage.resizeIfNeeded(96, 96, image!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}

class _ActivitySkeleton extends StatelessWidget {
  const _ActivitySkeleton();
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

class _ActivityError extends StatelessWidget {
  final VoidCallback? onRetry;
  const _ActivityError({this.onRetry});
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

class _RefreshOrbit extends StatefulWidget {
  final bool loading;
  const _RefreshOrbit({required this.loading});
  @override
  State<_RefreshOrbit> createState() => _RefreshOrbitState();
}

class _RefreshOrbitState extends State<_RefreshOrbit>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_RefreshOrbit old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.loading && !MediaQuery.disableAnimationsOf(context)) {
      controller.repeat();
    } else {
      controller.stop();
      controller.value = 0;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.loading ? 'Refreshing activity' : 'Pull to refresh activity',
    liveRegion: true,
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      child: SizedBox(
        width: 40,
        height: 40,
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => CustomPaint(
            painter: _RefreshOrbitPainter(
              controller.value,
              Theme.of(context).brightness == Brightness.dark,
            ),
          ),
        ),
      ),
    ),
  );
}

class _RefreshOrbitPainter extends CustomPainter {
  final double phase;
  final bool dark;
  const _RefreshOrbitPainter(this.phase, this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    final color = dark ? VibeColors.lime : const Color(0xff62802d);
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      11,
      Paint()
        ..color = color.withValues(alpha: .35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      center +
          Offset(
            math.cos(phase * math.pi * 2) * 11,
            math.sin(phase * math.pi * 2) * 11,
          ),
      3,
      Paint()..color = color,
    );
    canvas.drawCircle(center, 2, Paint()..color = color.withValues(alpha: .55));
  }

  @override
  bool shouldRepaint(_RefreshOrbitPainter old) =>
      phase != old.phase || dark != old.dark;
}

/// Offline, static vector art: a relaxed orbit rather than a notification banner.
class _QuietOrbitPainter extends CustomPainter {
  final bool dark;
  const _QuietOrbitPainter(this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / 360, size.height / 240);
    canvas.save();
    canvas.translate(
      (size.width - 360 * scale) / 2,
      (size.height - 240 * scale) / 2,
    );
    canvas.scale(scale);
    final ink = dark ? VibeColors.lilac : VibeColors.ink;
    canvas.drawCircle(
      const Offset(180, 120),
      110,
      Paint()
        ..shader = RadialGradient(
          colors: [
            VibeColors.lilac.withValues(alpha: dark ? .055 : .12),
            Colors.transparent,
          ],
        ).createShader(const Rect.fromLTWH(70, 10, 220, 220)),
    );
    canvas.save();
    canvas.translate(180, 124);
    canvas.rotate(-.38);
    final line = Paint()
      ..color = ink.withValues(alpha: dark ? .25 : .22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 280, height: 130),
      line,
    );
    canvas.rotate(.82);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 240, height: 144),
      line,
    );
    canvas.restore();
    canvas.drawCircle(
      const Offset(104, 136),
      44,
      Paint()..color = VibeColors.peach,
    );
    final shape = Path()
      ..moveTo(157, 54)
      ..cubicTo(210, 30, 253, 77, 239, 127)
      ..cubicTo(234, 174, 195, 197, 151, 181)
      ..cubicTo(118, 159, 110, 81, 157, 54)
      ..close();
    canvas.drawPath(
      shape,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [VibeColors.lilac, Color(0xffbba2e4)],
        ).createShader(const Rect.fromLTWH(116, 42, 132, 146)),
    );
    canvas.save();
    canvas.clipPath(shape);
    for (var i = 0; i < 100; i++) {
      canvas.drawCircle(
        Offset(
          116 + ((i * 47) % 132).toDouble(),
          42 + ((i * 71) % 146).toDouble(),
        ),
        .65,
        Paint()..color = VibeColors.ink.withValues(alpha: .09),
      );
    }
    canvas.restore();
    final face = Paint()
      ..color = VibeColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      const Rect.fromLTWH(150, 105, 14, 8),
      .15,
      math.pi - .3,
      false,
      face,
    );
    canvas.drawArc(
      const Rect.fromLTWH(190, 105, 14, 8),
      .15,
      math.pi - .3,
      false,
      face,
    );
    canvas.drawArc(
      const Rect.fromLTWH(164, 123, 30, 19),
      .1,
      math.pi - .2,
      false,
      face,
    );
    canvas.drawCircle(
      const Offset(266, 77),
      12,
      Paint()..color = VibeColors.lime,
    );
    canvas.drawPath(
      starPath(const Offset(88, 64), 10, 4),
      Paint()..color = VibeColors.peach,
    );
    canvas.drawPath(
      starPath(const Offset(265, 170), 7, 2.5),
      Paint()..color = ink.withValues(alpha: .6),
    );
    canvas.drawCircle(
      const Offset(54, 142),
      2.5,
      Paint()..color = ink.withValues(alpha: .45),
    );
    canvas.drawCircle(
      const Offset(300, 128),
      2,
      Paint()..color = ink.withValues(alpha: .45),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QuietOrbitPainter old) => dark != old.dark;
}
