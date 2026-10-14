import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'activity/activity_art.dart';
import 'activity/activity_header.dart';
import 'activity/activity_labels.dart';
import 'activity/activity_list.dart';

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
    final groups = items.map((item) => activityGroups[item['type']]).toSet();
    final filters = [
      'All',
      for (final group in activityGroupOrder)
        if (groups.contains(group)) group,
    ];
    final filter = filters.contains(selected) ? selected : 'All';
    final filtered = filter == 'All'
        ? items
        : items
              .where((item) => activityGroups[item['type']] == filter)
              .toList(growable: false);
    final now = widget.now ?? DateTime.now();

    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final metrics = ActivityHeaderMetrics.measure(
                context,
                constraints.maxWidth - 48,
              );
              final scroll = CustomScrollView(
                physics: widget.onRefresh == null
                    ? null
                    : const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: ActivityHeader(
                      captionHeight: metrics.captionHeight,
                      headingHeight: metrics.headingHeight,
                      filterHeight: metrics.filterHeight,
                      filters: filters,
                      selected: filter,
                      onSelect: (value) => setState(() => selected = value),
                      onSettings: widget.onSettings,
                      onMarkAllRead: widget.onMarkAllRead,
                    ),
                  ),
                  ActivitySliver(
                    activity: widget.activity,
                    filtered: filtered,
                    now: now,
                    maxHeight: constraints.maxHeight,
                    onExplore: widget.onExplore,
                    onRetry: widget.onRetry,
                    onLoadMore: widget.onLoadMore,
                    loadingMore: widget.loadingMore,
                    openNotification: widget.openNotification,
                    markRead: widget.markRead,
                    dismiss: widget.dismiss,
                    avatarImage: widget.avatarImage,
                    actions: widget.actions,
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
                    PositionedDirectional(
                      top: 8,
                      start: 0,
                      end: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: RefreshOrbit(
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
