import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'activity.dart';
import 'chat.dart';
import 'discovery.dart';
import 'relationship.dart';

import '../core/activity_state.dart';
import '../core/api.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../shared/profile_space.dart';

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final login = VibePanel(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VibeTag('YOUR NEXT CHAPTER', color: VibeColors.lilac),
          const SizedBox(height: 24),
          Text(
            'Come as you are.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'Your people are out there. Your space starts here.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 30),
          if (devLoginEnabled) ...[
            const Text(
              'Development preview',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick a local account to explore your profile and privacy controls.',
              style: TextStyle(fontSize: 13, height: 1.7),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: session.isLoading
                  ? null
                  : () => ref.read(sessionProvider.notifier).login(anjaliId),
              child: Text(
                session.isLoading ? 'Connecting…' : 'Continue as Anjali',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: session.isLoading
                  ? null
                  : () => ref.read(sessionProvider.notifier).login(nikoId),
              child: const Text('Continue as Niko'),
            ),
            if (session.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Text(
                  session.error.toString(),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ] else
            const EmptyCard(
              icon: Icons.waving_hand_outlined,
              title: 'We’re getting ready',
              description: 'Sign-ups will open when Kairova is ready. Good things take a little care.',
            ),
          const SizedBox(height: 20),
          TextButton.icon(
            onPressed: () => context.go('/design'),
            icon: const Icon(Icons.design_services_outlined, size: 18),
            label: const Text('Explore the full design'),
          ),
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 16),
          const Row(
            children: [
              Icon(Icons.tune_rounded, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'YOUR SPACE. YOUR RULES.',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    final story = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            BrandMark(size: 44),
            SizedBox(width: 12),
            Flexible(
              child: Text(
                'kairova',
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.8,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 44),
        const VibeTag('A DIFFERENT KIND OF SOCIAL', icon: Icons.auto_awesome),
        const SizedBox(height: 22),
        Text(
          'Your people.\nYour plot.\nYour kind of weird.',
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: MediaQuery.sizeOf(context).width < 600 ? 46 : 62,
            height: 1.02,
            fontWeight: FontWeight.w700,
            letterSpacing: -2.8,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Less performing. More connecting.\nA little corner of the internet that feels like you.',
          style: TextStyle(
            height: 1.7,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 28),
        const VibeArt(height: 250),
      ],
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 600 ? 22 : 44,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: LayoutBuilder(
                builder: (context, box) =>
                    box.maxWidth >= 820 &&
                        MediaQuery.textScalerOf(context).scale(1) < 1.4
                    ? Row(
                        children: [
                          Expanded(flex: 6, child: story),
                          const SizedBox(width: 64),
                          Expanded(flex: 5, child: login),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [story, const SizedBox(height: 28), login],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(profileProvider).asData?.value;
    return ReadingWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        children: [
          VibeHero(
            tag: p == null ? 'WELCOME TO YOUR ORBIT' : 'HEY, ${p.displayName}',
            title: 'Less noise.\nMore your people.',
            subtitle: 'For the real ones, the random thoughts, and the little things that turn into big memories.',
            dark: true,
            action: FilledButton.icon(
              onPressed: () => context.go('/profile/privacy'),
              icon: const Icon(Icons.arrow_outward_rounded, size: 18),
              label: const Text('Set your privacy'),
            ),
          ),
          const SectionTitle(
            'Make it feel like you',
            label: 'A GOOD PLACE TO START',
          ),
          TwoUp(
            first: FeatureTile(
              icon: Icons.face_6_outlined,
              title: 'Main character, always.',
              description: 'A bio, a name, a little personality. Give your profile your own kind of energy.',
              color: VibeColors.pink,
              action: TextButton.icon(
                onPressed: () => context.go('/profile/edit'),
                icon: const Icon(Icons.arrow_outward, size: 16),
                label: const Text('Make it yours'),
              ),
            ),
            second: FeatureTile(
              icon: Icons.tune_rounded,
              title: 'Your circle. Your call.',
              description: 'Decide who sees your world. Start small, open up when it feels right.',
              color: VibeColors.lime,
              action: TextButton.icon(
                onPressed: () => context.go('/profile/privacy'),
                icon: const Icon(Icons.arrow_outward, size: 16),
                label: const Text('Privacy controls'),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => context.go('/design'),
            icon: const Icon(Icons.design_services_outlined),
            label: const Text('Explore all screen designs'),
          ),
          const SectionTitle('The next chapter', label: 'ON THE WAY'),
          VibePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const VibeTag(
                  'STORIES + FEED / COMING SOON',
                  color: VibeColors.peach,
                ),
                const SizedBox(height: 20),
                Text(
                  'Good moments deserve a little space.',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  'Sharing is still taking shape. Your feed will live here once posts and stories are ready.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
        if (context.mounted) showMessage(context, e.toString());
      }
    }

    return ActivityView(
      activity: state.whenData((value) => value.items),
      onExplore: () => context.go('/discover'),
      onSettings: () => context.go('/profile/privacy'),
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
          context.go('/discover/person/$actor');
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
  Widget build(BuildContext context) => const PeopleDiscovery();
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
        if (blocked) context.go('/discover');
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> message(String name) async {
    if (!chatSupported) {
      showMessage(context, 'Chats are available in the Android and iOS apps.');
      return;
    }
    setState(() => busy = true);
    try {
      final engine = await ref.read(chatEngineProvider.future);
      final id = await engine!.open(widget.id);
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
          final messageButton = FilledButton.tonalIcon(
            key: const Key('message-person'),
            onPressed: busy ? null : () => message(profile.displayName),
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
            label: const Text('Message'),
          );
          final actions = RelationshipBar(
            profile: profile,
            trailing: messageButton,
          );
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => context.go('/discover'),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Discover'),
                    ),
                    const Spacer(),
                    if (profile.locked)
                      IconButton(
                        tooltip: 'Block',
                        onPressed: busy ? null : block,
                        icon: const Icon(Icons.block_rounded),
                      ),
                  ],
                ),
              ),
              if (!profile.locked)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                  child: Align(alignment: Alignment.centerLeft, child: actions),
                ),
              Expanded(
                child: profile.locked
                    ? LockedProfile(profile: profile, actions: actions)
                    : ProfileSpace(
                        profile: profile,
                        onBlock: busy ? null : block,
                      ),
              ),
            ],
          );
        },
        error: (e, s) => ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextButton.icon(
                onPressed: () => context.go('/discover'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Discover'),
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
}
