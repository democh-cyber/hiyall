import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'activity_labels.dart';
import 'activity_row.dart';
import 'activity_states.dart';

/// The body slivers under the pinned header: skeleton, error, empty state, or
/// the lazily built day-grouped notification list.
class ActivitySliver extends StatelessWidget {
  final AsyncValue<List<Map<String, dynamic>>> activity;
  final List<Map<String, dynamic>> filtered;
  final DateTime now;
  final double maxHeight;
  final VoidCallback? onExplore, onRetry, onLoadMore;
  final bool loadingMore;
  final VoidCallback? Function(Map<String, dynamic>)? openNotification;
  final VoidCallback? Function(Map<String, dynamic>)? markRead, dismiss;
  final ImageProvider? Function(Map<String, dynamic>)? avatarImage;
  final Widget? Function(Map<String, dynamic>)? actions;
  const ActivitySliver({
    super.key,
    required this.activity,
    required this.filtered,
    required this.now,
    required this.maxHeight,
    this.onExplore,
    this.onRetry,
    this.onLoadMore,
    this.loadingMore = false,
    this.openNotification,
    this.markRead,
    this.dismiss,
    this.avatarImage,
    this.actions,
  });

  @override
  Widget build(BuildContext context) => activity.when(
    skipLoadingOnRefresh: false,
    loading: () => const SliverPadding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 32),
      sliver: ActivitySkeleton(),
    ),
    error: (_, _) => SliverToBoxAdapter(child: ActivityError(onRetry: onRetry)),
    data: (_) => filtered.isEmpty
        ? SliverToBoxAdapter(
            child: ActivityEmpty(
              artHeight: (maxHeight * .3).clamp(160.0, 280.0),
              onExplore: onExplore,
            ),
          )
        : SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            sliver: SliverList.builder(
              itemCount: filtered.length,
              itemBuilder: _item,
            ),
          ),
  );

  Widget _item(BuildContext context, int index) {
    if (index >= filtered.length - 3) {
      // Ask for the next page before the end is reached.
      final more = onLoadMore;
      if (more != null && !loadingMore) {
        WidgetsBinding.instance.addPostFrameCallback((_) => more());
      }
    }
    final item = filtered[index];
    final day = activityDayLabel(item, now, context);
    final showDay =
        index == 0 ||
        day != activityDayLabel(filtered[index - 1], now, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showDay && day.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 8 : 24, bottom: 12),
            child: Text(
              day.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ActivityRow(
          key: ValueKey(item['notificationId']),
          item: item,
          now: now,
          onOpen: openNotification?.call(item),
          onMarkRead: markRead?.call(item),
          onDismiss: dismiss?.call(item),
          avatarImage: avatarImage,
          actions: actions?.call(item),
        ),
      ],
    );
  }
}
