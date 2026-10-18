import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/notices.dart';
import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import '../shared/unread_dot.dart';
import '../shared/widgets.dart';
import 'notice_markup.dart';
import 'settings.dart' show timeAgo;

/// How a notice category looks and is called. Fixed pastel fills with dark ink, like the rest of the
/// app's tags, so the label reads the same in light and dark.
class NoticeCategoryStyle {
  final String label;
  final IconData icon;
  final Color fill;
  const NoticeCategoryStyle(this.label, this.icon, this.fill);

  static NoticeCategoryStyle of(NoticeCategory c) => switch (c) {
    NoticeCategory.safety => const NoticeCategoryStyle(
      'Safety',
      Icons.shield_outlined,
      VibeColors.peach,
    ),
    NoticeCategory.news => const NoticeCategoryStyle(
      'News',
      Icons.campaign_outlined,
      VibeColors.lilac,
    ),
    NoticeCategory.update => const NoticeCategoryStyle(
      'Update',
      Icons.auto_awesome_outlined,
      VibeColors.mint,
    ),
  };
}

/// The small "Safety" / "News" / "Update" label with its icon.
class NoticeCategoryChip extends StatelessWidget {
  final NoticeCategory category;
  const NoticeCategoryChip(this.category, {super.key});
  @override
  Widget build(BuildContext context) {
    final style = NoticeCategoryStyle.of(category);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.fill,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(style.icon, size: 15, color: VibeColors.ink),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                style.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: VibeColors.ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings > Help & Safety > Notices: short posts from the Hiyall team, pinned ones first.
class NoticesScreen extends ConsumerStatefulWidget {
  const NoticesScreen({super.key});
  @override
  ConsumerState<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends ConsumerState<NoticesScreen> {
  bool onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 600) {
      ref.read(noticeBoardProvider.notifier).loadMore().catchError((_) {});
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(noticeBoardProvider);
    final value = board.asData?.value;
    final notices = value?.ordered ?? const <Notice>[];
    return ReadingWidth(
      child: RefreshIndicator(
        onRefresh: () async {
          try {
            await ref.read(noticeBoardProvider.notifier).refresh();
          } catch (_) {}
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: onScroll,
          child: ListView(
            key: const Key('notices-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => context.canPop()
                      ? context.pop()
                      : context.go('/profile/help'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Help & Safety'),
                ),
              ),
              Semantics(
                header: true,
                child: Text(
                  'Notices',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'News and safety notes from the Hiyall team.',
                style: TextStyle(
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              if (board.isLoading && value == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (value == null)
                FailureCard(
                  key: const Key('notices-error'),
                  error: board.error!,
                  retry: () => ref.invalidate(noticeBoardProvider),
                )
              else if (notices.isEmpty)
                const EmptyCard(
                  key: Key('notices-empty'),
                  icon: Icons.notifications_none_rounded,
                  title: 'Nothing new right now',
                  description: 'When the Hiyall team has news or a safety note for you, it shows up here.',
                )
              else ...[
                for (final notice in notices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: NoticeCard(notice),
                  ),
                if (value.loadingMore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class NoticeCard extends StatelessWidget {
  final Notice notice;
  const NoticeCard(this.notice, {super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final style = NoticeCategoryStyle.of(notice.category);
    final when = notice.publishedAt;
    return Semantics(
      container: true,
      label:
          '${notice.unread ? 'New. ' : ''}${style.label}. ${notice.pinned ? 'Pinned. ' : ''}${notice.title}',
      child: Container(
        key: Key('notice-${notice.id}'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: notice.unread ? tokens.unreadRow : tokens.surface,
          borderRadius: BorderRadius.circular(VibeRadius.surface - 6),
          border: Border.all(color: tokens.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (notice.unread) ...[
                  UnreadDot(
                    key: Key('notice-unread-${notice.id}'),
                    label: 'New',
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(child: NoticeCategoryChip(notice.category)),
                if (notice.pinned) ...[
                  const SizedBox(width: 10),
                  Icon(
                    Icons.push_pin_outlined,
                    size: 16,
                    color: tokens.textSecondary,
                    semanticLabel: 'Pinned',
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Semantics(
              header: true,
              child: Text(
                notice.title,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800, color: tokens.text),
              ),
            ),
            const SizedBox(height: 8),
            NoticeBody(notice.body),
            if (when != null) ...[
              const SizedBox(height: 12),
              Text(
                timeAgo(when),
                style: TextStyle(fontSize: 12.5, color: tokens.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The compact card on Home for the first pinned notice of category safety. It can be dismissed until
/// the app is closed; nothing about that is saved or sent.
class PinnedSafetyBanner extends ConsumerWidget {
  const PinnedSafetyBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(noticeSummaryProvider).asData?.value.pinnedSafety;
    if (notice == null ||
        ref.watch(dismissedBannersProvider).contains(notice.id)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Semantics(
        container: true,
        label: 'Safety notice. ${notice.title}',
        child: Material(
          key: const Key('home-safety-banner'),
          color: VibeColors.peach,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Expanded(
                child: PressScale(
                  minHeight: 56,
                  borderRadius: BorderRadius.circular(20),
                  semanticLabel: 'Read the safety notice: ${notice.title}',
                  onTap: () => context.push('/profile/notices'),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      14,
                      10,
                      4,
                      10,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.shield_outlined,
                          color: VibeColors.ink,
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Safety notice',
                                style: TextStyle(
                                  color: VibeColors.ink,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: .4,
                                ),
                              ),
                              Text(
                                notice.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: VibeColors.ink,
                                  fontWeight: FontWeight.w700,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('home-safety-banner-dismiss'),
                tooltip: 'Hide for now',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.close_rounded, color: VibeColors.ink),
                onPressed: () =>
                    ref.read(dismissedBannersProvider.notifier).hide(notice.id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
