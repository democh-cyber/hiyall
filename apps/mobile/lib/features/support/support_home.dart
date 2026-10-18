import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/support.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/unread_dot.dart';
import '../../shared/widgets.dart';
import '../settings.dart' show timeAgo;
import 'support_widgets.dart';

/// Settings > Help & Safety > Message support: the member's conversations with the Hiyall team.
class SupportHomeScreen extends ConsumerStatefulWidget {
  const SupportHomeScreen({super.key});
  @override
  ConsumerState<SupportHomeScreen> createState() => _SupportHomeScreenState();
}

class _SupportHomeScreenState extends ConsumerState<SupportHomeScreen> {
  bool onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 600) {
      ref.read(supportThreadsProvider.notifier).loadMore().catchError((_) {});
    }
    return false;
  }

  void newMessage() => context.push('/profile/support/new');

  @override
  Widget build(BuildContext context) {
    final threads = ref.watch(supportThreadsProvider);
    final value = threads.asData?.value;
    return ReadingWidth(
      child: RefreshIndicator(
        onRefresh: () async {
          try {
            await ref.read(supportThreadsProvider.notifier).refresh();
            ref.invalidate(supportUnreadProvider);
          } catch (_) {}
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: onScroll,
          child: ListView(
            key: const Key('support-list'),
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
                  'Message support',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Write to the Hiyall team inside the app. A real person reads it.',
                style: TextStyle(
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('support-new'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: newMessage,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('New message'),
              ),
              const SizedBox(height: 18),
              if (threads.isLoading && value == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (value == null)
                FailureCard(
                  key: const Key('support-error'),
                  error: threads.error!,
                  retry: () => ref.invalidate(supportThreadsProvider),
                )
              else if (value.items.isEmpty)
                const EmptyCard(
                  key: Key('support-empty'),
                  icon: Icons.support_agent_rounded,
                  title: 'No messages yet',
                  description: 'Stuck, worried or found a bug? Send us a message and we’ll write back here.',
                )
              else ...[
                for (final thread in value.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SupportThreadRow(thread),
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

/// One conversation in the list: topic, state, the start of the last message and when.
class SupportThreadRow extends StatelessWidget {
  final SupportThread thread;
  const SupportThreadRow(this.thread, {super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final style = SupportCategoryStyle.of(thread.category);
    final who = thread.lastAuthor == 'staff' ? 'Hiyall team: ' : 'You: ';
    return Semantics(
      container: true,
      button: true,
      label:
          '${thread.unread ? 'New reply. ' : ''}${style.label}, ${thread.open ? 'open' : 'closed'}. $who${thread.preview}',
      child: ExcludeSemantics(
        child: Material(
          color: thread.unread ? tokens.unreadRow : tokens.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: tokens.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('support-thread-${thread.id}'),
            onTap: () => context.push('/profile/support/${thread.id}'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(style.icon, color: tokens.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                style.label,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: tokens.text,
                                ),
                              ),
                              SupportStatusPill(open: thread.open),
                            ],
                          ),
                          if (thread.preview.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '$who${thread.preview}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                height: 1.35,
                                color: tokens.textSecondary,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            timeAgo(thread.lastMessageAt),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (thread.unread) ...[
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: UnreadDot(
                          key: Key('support-unread-${thread.id}'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
