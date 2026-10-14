import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/user_error.dart';
import '../../shared/person_avatar.dart';
import '../../shared/person_link.dart';
import '../../shared/widgets.dart';
import 'paged_list.dart';

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const Key('confirm-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// The frame every list screen shares: a back button, a title, optional lines
/// above the rows, then loading, error, empty and paged states.
class ListPage<T> extends StatelessWidget {
  final String title, backLabel, backTo;
  final PagedList<T> list;
  final List<Widget> header;
  final Widget Function(T item) row;
  final Widget empty;

  /// Shown instead of the retry card for failures that are not worth retrying.
  final Widget? Function(Object error)? calm;
  final Widget? trailing;
  const ListPage({
    super.key,
    required this.title,
    required this.backLabel,
    required this.backTo,
    required this.list,
    required this.row,
    required this.empty,
    this.header = const [],
    this.calm,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => ReadingWidth(
    child: ListenableBuilder(
      listenable: list,
      builder: (context, _) {
        final error = list.error;
        // Loading, failure and empty states are one box; real rows are built
        // lazily, so a long list only lays out what is on screen.
        Widget? state;
        if (!list.loaded && list.loading) {
          state = const VibeLoading();
        } else if (error != null && list.items.isEmpty) {
          state =
              calm?.call(error) ?? FailureCard(error: error, retry: list.load);
        } else if (list.loaded && list.items.isEmpty) {
          state = empty;
        }
        final footer = list.cursor != null || list.loadingMore
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: list.loadingMore
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      )
                    : OutlinedButton(
                        key: const Key('list-more'),
                        onPressed: () async {
                          final failure = await list.more();
                          if (failure != null && context.mounted) {
                            showFailure(context, failure);
                          }
                        },
                        child: const Text('Show more'),
                      ),
              )
            : null;
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 240 &&
                list.cursor != null &&
                !list.loadingMore &&
                !list.loading) {
              list.more();
            }
            return false;
          },
          child: RefreshIndicator(
            onRefresh: list.load,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: TextButton.icon(
                                key: const Key('list-back'),
                                onPressed: () => goBack(context, backTo),
                                icon: const Icon(Icons.arrow_back),
                                label: Text(backLabel),
                              ),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: Semantics(
                                    header: true,
                                    child: Text(
                                      title,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium,
                                    ),
                                  ),
                                ),
                                ?trailing,
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...header,
                          ],
                        ),
                      ),
                      if (state != null)
                        SliverToBoxAdapter(child: state)
                      else
                        SliverList.builder(
                          itemCount: list.items.length,
                          itemBuilder: (context, i) => row(list.items[i]),
                        ),
                      if (state == null && footer != null)
                        SliverToBoxAdapter(child: footer),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// One person in a list: tap the head to open their profile, with any actions
/// on a line below so they never crowd the name at large text sizes.
class PersonRow extends StatelessWidget {
  final Person person;
  final String subtitle;
  final VoidCallback onOpen;
  final List<Widget> actions;
  const PersonRow({
    super.key,
    required this.person,
    required this.subtitle,
    required this.onOpen,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onOpen,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  PersonAvatar(
                    name: person.name,
                    avatarUrl: person.avatarUrl,
                    userId: person.userId,
                    radius: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          person.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 56, top: 2),
              child: Wrap(spacing: 8, runSpacing: 4, children: actions),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}

Widget listAction(
  String label,
  VoidCallback? onPressed, {
  required Key key,
  IconData? icon,
  bool filled = false,
}) {
  final style = (filled ? FilledButton.styleFrom : OutlinedButton.styleFrom)(
    visualDensity: VisualDensity.compact,
    minimumSize: const Size(48, 40),
  );
  final text = Text(label);
  return filled
      ? FilledButton.tonalIcon(
          key: key,
          onPressed: onPressed,
          style: style,
          icon: icon == null ? null : Icon(icon, size: 16),
          label: text,
        )
      : OutlinedButton.icon(
          key: key,
          onPressed: onPressed,
          style: style,
          icon: icon == null ? null : Icon(icon, size: 16),
          label: text,
        );
}

Widget privateList(Object error) =>
    error is ApiFailure && error.code == 'CONNECTIONS_PRIVATE'
    ? const EmptyCard(
        icon: Icons.lock_outline_rounded,
        title: 'Not shared',
        description: 'This member keeps their lists to themselves.',
      )
    : FailureCard(error: error, retry: () {});
