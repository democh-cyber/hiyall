import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'activity.dart';
import 'chat.dart';
import 'discover_hub.dart';
import 'people_lists.dart';
import 'pulse.dart';
import 'relationship.dart';
import 'safety.dart';
import 'say_hi_ui.dart';
import 'visitor_profile.dart';

import '../core/activity_state.dart';
import '../core/api.dart';
import '../core/state.dart';
import '../shared/person_link.dart';
import '../shared/widgets.dart';
import '../shared/profile_space.dart';
import '../core/user_error.dart';
import 'shop/profile_details_card.dart';
import 'shop/spend_gate.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(activityProvider);
    final controller = ref.read(activityProvider.notifier);
    final data = state.asData?.value;
    Future<void> guarded(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        if (context.mounted) showFailure(context, e);
      }
    }

    return ActivityView(
      activity: state.whenData((value) => value.items),
      onExplore: () => context.go('/discover'),
      onSettings: () => context.go('/profile/settings'),
      onRetry: () => ref.invalidate(activityProvider),
      onRefresh: () => guarded(controller.refresh),
      onLoadMore: data?.nextCursor == null
          ? null
          : () => guarded(controller.loadMore),
      loadingMore: data?.loadingMore ?? false,
      onMarkAllRead: (data?.unread ?? 0) == 0
          ? null
          : () => guarded(controller.markAllRead),
      markRead: (item) => item['readAt'] != null
          ? null
          : () => guarded(
              () => controller.markRead(item['notificationId'] as String),
            ),
      openNotification: (item) {
        final actors = item['actors'] as List? ?? const [];
        if (actors.isEmpty) return null;
        final actor = (actors.first as Map)['userId'] as String;
        return () {
          if (item['readAt'] == null) {
            guarded(
              () => controller.markRead(item['notificationId'] as String),
            );
          }
          if (item['event'] == 'space.requested') {
            context.push('/spaces/${item['targetId']}/members?state=pending');
          } else if (item['event'] == 'comment.replied') {
            // A reply to your comment opens the post it is on.
            context.push('/post/${item['targetId']}');
          } else if (item['targetType'] == 'space') {
            context.push('/spaces/${item['targetId']}');
          } else {
            openPerson(context, actor);
          }
        };
      },
      actions: (item) => isPendingRequest(item)
          ? Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: ValueKey('accept-${item['notificationId']}'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      guarded(() => controller.respond(item, true)),
                  child: const Text('Accept'),
                ),
                OutlinedButton(
                  key: ValueKey('decline-${item['notificationId']}'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      guarded(() => controller.respond(item, false)),
                  child: const Text('Decline'),
                ),
              ],
            )
          : null,
    );
  }
}

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});
  @override
  Widget build(BuildContext context) => const DiscoverHub();
}

class PersonScreen extends ConsumerStatefulWidget {
  final String id;
  const PersonScreen({super.key, required this.id});
  @override
  ConsumerState<PersonScreen> createState() => _PersonState();
}

class _PersonState extends ConsumerState<PersonScreen> {
  bool busy = false;
  Future<void> block([bool blocked = true]) async {
    setState(() => busy = true);
    try {
      await ref
          .read(apiProvider)
          .block(ref.read(sessionProvider).asData!.value!, widget.id, blocked);
      ref.invalidate(otherProfileProvider(widget.id));
      // Block changes also change the owner's derived connection counts.
      ref.invalidate(profileProvider);
      if (mounted) {
        showMessage(
          context,
          blocked ? 'Account blocked.' : 'Your block was removed.',
        );
        if (blocked) goBack(context);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> options(Profile profile) =>
      showPersonOptions(context, ref, profile, onBlock: block);

  Future<void> message(String name) async {
    if (!chatSupported) {
      showMessage(context, 'Chats are available in the Android and iOS apps.');
      return;
    }
    setState(() => busy = true);
    try {
      final engine = await ref.read(chatEngineProvider.future);
      // Past the free allowance a new chat costs coins: asks first (billing, adults only).
      if (!mounted) return;
      final id = await openChatConfirmingSpend(
        context,
        ref,
        open: (cost) => engine!.open(widget.id, confirmCost: cost),
      );
      if (id == null) return;
      if (mounted) {
        context.go(
          '/chats/$id?peer=${Uri.encodeQueryComponent(widget.id)}&name=${Uri.encodeQueryComponent(name)}',
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(otherProfileProvider(widget.id))
      .when(
        data: (profile) {
          // Anyone can message anyone; following is optional.
          final messageButton = FilledButton.icon(
            key: const Key('message-person'),
            onPressed: busy ? null : () => message(profile.displayName),
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
            label: const Text('Message'),
          );
          final actions = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RelationshipBar(
                profile: profile,
                trailing: messageButton,
                showFriendship: profile.locked,
                messageFirst: !profile.locked,
                extra: SayHiProfileButton(person: profile),
              ),
              SayHiNote(userId: profile.userId),
              if (profile.detailsLocked)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ProfileDetailsLockedCard(userId: profile.userId),
                ),
            ],
          );
          return SayHiEffects(announce: true, child: _body(profile, actions));
        },
        error: (e, s) => ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextButton.icon(
                onPressed: () => goBack(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
              FailureCard(
                error: e,
                retry: () => ref.invalidate(otherProfileProvider(widget.id)),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: busy ? null : () => block(false),
                icon: const Icon(Icons.undo),
                label: const Text('Remove my block on this account'),
              ),
            ],
          ),
        ),
        loading: () => const ProfileSkeleton(),
      );

  Widget _body(Profile profile, Widget actions) {
    if (!profile.locked) {
      return VisitorProfile(
        profile: profile,
        actions: actions,
        onBack: () => goBack(context),
        onOptions: busy ? null : () => options(profile),
        statActions: otherStatActions(context, ref, profile),
        statsNote: profile.socialStats != null && !profile.canSeeConnections
            ? 'Their followers and following lists are private.'
            : null,
        contentFor: (tab) => profileContent(ref, profile.userId, tab),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => goBack(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
              const Spacer(),
              IconButton(
                key: const Key('profile-options'),
                tooltip: 'Profile options',
                onPressed: busy ? null : () => options(profile),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: LockedProfile(profile: profile, actions: actions),
        ),
      ],
    );
  }
}
