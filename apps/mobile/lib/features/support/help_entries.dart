import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notices.dart';
import '../../core/support.dart';
import '../../shared/unread_dot.dart';
import '../../shared/widgets.dart';

/// Whether anything from the Hiyall team is waiting: an unread notice or a reply in support. Drives
/// the dot on the Settings entry. A failed read counts as "nothing".
final helpUnreadProvider = Provider<bool>(
  (ref) =>
      (ref.watch(noticeSummaryProvider).asData?.value.hasUnread ?? false) ||
      (ref.watch(supportUnreadProvider).asData?.value ?? 0) > 0,
);

/// The "Talk to us" panel at the top of Help & Safety: Message support and Notices, each with a dot when
/// something is waiting.
class HelpHiyallSection extends ConsumerWidget {
  const HelpHiyallSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notices =
        ref.watch(noticeSummaryProvider).asData?.value.hasUnread ?? false;
    final replies = ref.watch(supportUnreadProvider).asData?.value ?? 0;
    Widget trailing(bool dot) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[const UnreadDot(label: 'New'), const SizedBox(width: 8)],
        const Icon(Icons.chevron_right_rounded),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
            child: Semantics(
              header: true,
              child: Text(
                'FROM HIYALL',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          VibePanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ListTile(
                  key: const Key('help-support'),
                  minTileHeight: 64,
                  leading: const Icon(Icons.forum_outlined),
                  title: const Text(
                    'Message support',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    replies > 0
                        ? 'The team replied'
                        : 'Write to the Hiyall team inside the app',
                  ),
                  trailing: trailing(replies > 0),
                  onTap: () => context.push('/profile/support'),
                ),
                ListTile(
                  key: const Key('help-notices'),
                  minTileHeight: 64,
                  leading: const Icon(Icons.campaign_outlined),
                  title: const Text(
                    'Notices',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    notices
                        ? 'There’s something new'
                        : 'News and safety notes from the team',
                  ),
                  trailing: trailing(notices),
                  onTap: () => context.push('/profile/notices'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
