import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/activity_state.dart';
import '../core/api.dart';
import '../core/feed_state.dart';
import '../core/home_prefs.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/press_scale.dart';
import '../shared/segmented.dart';
import '../shared/widgets.dart';
import 'home_cards.dart';
import 'home_vibe.dart';
import 'live_sync.dart';
import 'pulse.dart';

export 'home_cards.dart' show homeSuggestionsProvider, missingProfileParts;

/// The Home page's width, from which it lays out as two columns: Pulse in the
/// middle and the vibe check, "For you" and suggestions in a side rail.
const homeWideBreakpoint = 880.0;
const _feedMaxWidth = 640.0;
const _railWidth = 340.0;

/// A one-line hello that fits the hour: "gm Mira ☀️", "hey Mira 🌙",
/// "still up, Mira? 👀". Uses the first name only; with no name yet it
/// still reads naturally.
String homeGreeting(DateTime now, String? displayName) {
  final first = displayName?.trim().split(RegExp(r'\s+')).first ?? '';
  final hour = now.hour;
  String line(String withName, String without) =>
      first.isEmpty ? without : withName;
  if (hour < 5 || hour >= 23) {
    return line('still up, $first? 👀', 'still up? 👀');
  }
  if (hour < 12) return line('gm $first ☀️', 'gm ☀️');
  if (hour < 17) return line('hey $first 🌤️', 'hey 🌤️');
  return line('hey $first 🌙', 'hey 🌙');
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String mode = 'following';

  /// Whether the create button shows its label. It folds to a plain "+" while
  /// the page scrolls down and opens again on the way up.
  final extended = ValueNotifier<bool>(true);

  @override
  void dispose() {
    extended.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    ref.invalidate(homeSuggestionsProvider);
    ref.invalidate(profileProvider);
    ref.invalidate(storyTrayProvider);
    try {
      await ref.read(feedProvider(mode).notifier).refresh();
      await ref.read(activityProvider.notifier).refresh();
      await ref.read(chatUnreadProvider.notifier).refresh();
    } catch (_) {}
  }

  bool onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n.depth != 0) return false;
    // Fetch the next page while a screen or two of posts is still left.
    if (n.metrics.extentAfter < 1200) {
      ref.read(feedProvider(mode).notifier).loadMore().catchError((_) {});
    }
    if (n is ScrollUpdateNotification) {
      final delta = n.scrollDelta ?? 0;
      if (n.metrics.pixels <= 24 || delta < -4) {
        extended.value = true;
      } else if (delta > 4) {
        extended.value = false;
      }
    }
    return false;
  }

  void setMode(String next) => setState(() => mode = next);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= homeWideBreakpoint;
      return Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wide
                      ? _feedMaxWidth + 24 + _railWidth
                      : _feedMaxWidth,
                ),
                child: wide ? _wide(context) : _column(wide: false),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: HomeCreateButton(extended: extended),
          ),
        ],
      );
    },
  );

  Widget _wide(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: _column(wide: true)),
      const SizedBox(width: 24),
      SizedBox(
        width: _railWidth,
        child: ListView(
          key: const Key('home-rail'),
          padding: const EdgeInsets.fromLTRB(0, 8, 16, 120),
          children: const [
            StaggerIn(index: 0, child: HomeVibeStrip(wrap: true)),
            HomeProfileNudge(rail: true, topGap: 16),
            HomeForYou(rail: true, topGap: 28),
            SizedBox(height: 28),
            HomeSuggestions(rail: true),
          ],
        ),
      ),
    ],
  );

  /// The feed column: everything on a phone, just stories and Pulse beside the rail.
  Widget _column({required bool wide}) => RefreshIndicator(
    color: VibeColors.lime,
    backgroundColor: VibeColors.ink,
    onRefresh: refresh,
    child: NotificationListener<ScrollNotification>(
      onNotification: onScroll,
      child: CustomScrollView(
        key: const Key('home-scroll'),
        // Bouncy at the top so the pull-to-refresh feels springy.
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          if (!wide) ...[
            const SliverToBoxAdapter(
              child: StaggerIn(index: 0, child: _Greeting()),
            ),
            const SliverToBoxAdapter(
              child: StaggerIn(index: 1, child: HomeVibeStrip()),
            ),
            const SliverToBoxAdapter(
              child: StaggerIn(index: 2, child: HomeProfileNudge(topGap: 4)),
            ),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: wide ? 12 : 10),
              child: const StaggerIn(index: 3, child: StoryTray()),
            ),
          ),
          if (!wide)
            const SliverToBoxAdapter(
              child: StaggerIn(index: 4, child: HomeForYou(topGap: 12)),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              child: StaggerIn(
                index: 5,
                child: VibeSegmented<String>(
                  key: const Key('feed-mode'),
                  segments: const [
                    ('following', 'Your people'),
                    ('everyone', 'Everyone'),
                  ],
                  selected: mode,
                  onChanged: setMode,
                  keyFor: (v) => Key('feed-mode-$v'),
                ),
              ),
            ),
          ),
          _FeedSlivers(mode: mode, wide: wide),
        ],
      ),
    ),
  );
}

/// "gm Mira ☀️". Rebuilds on its own when the name arrives.
class _Greeting extends ConsumerWidget {
  const _Greeting();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(profileProvider.select((p) => p.value?.displayName));
    final text = homeGreeting(ref.watch(homeClockProvider)(), name);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Semantics(
        header: true,
        child: Text(
          text,
          key: const Key('home-greeting'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontSize: 30, letterSpacing: -1.2),
        ),
      ),
    );
  }
}

/// Pulse itself: the posts, with the suggestions carousel after about the
/// third one, and a calm look for loading, errors and a quiet feed.
class _FeedSlivers extends ConsumerWidget {
  final String mode;
  final bool wide;
  const _FeedSlivers({required this.mode, required this.wide});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedProvider(mode));
    final posts = feed.value?.items ?? const <Post>[];
    // The rail carries the suggestions on a wide screen.
    final suggestions =
        !wide &&
        ref.watch(
          homeSuggestionsProvider.select((s) => s.value?.isNotEmpty ?? false),
        );
    // After the third post, or at the end of a short feed.
    final slot = posts.isEmpty ? -1 : math.min(3, posts.length);
    final inline = suggestions && posts.isNotEmpty;
    const side = EdgeInsets.symmetric(horizontal: 16);

    if (!feed.hasValue && feed.hasError) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: side,
          child: FailureCard(
            error: feed.error!,
            retry: () => ref.invalidate(feedProvider(mode)),
          ),
        ),
      );
    }
    if (!feed.hasValue) {
      return const SliverToBoxAdapter(child: _FeedSkeleton());
    }
    if (posts.isEmpty) {
      return SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: side,
              child: _QuietFeed(mode: mode),
            ),
            if (suggestions) ...[
              const SizedBox(height: 24),
              const HomeSuggestions(),
            ],
            const SizedBox(height: 120),
          ],
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverList.builder(
          itemCount: posts.length + (inline ? 1 : 0),
          itemBuilder: (context, i) {
            if (inline && i == slot) {
              return const Padding(
                padding: EdgeInsets.only(bottom: 22),
                child: HomeSuggestions(),
              );
            }
            final index = inline && i > slot ? i - 1 : i;
            final card = Padding(
              padding: side,
              child: PostCard(post: posts[index], mode: mode),
            );
            return index < 3 ? StaggerIn(index: 6 + index, child: card) : card;
          },
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 120),
            child: feed.value?.loadingMore ?? false
                ? const Center(child: CircularProgressIndicator())
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// Where the first post will be, while Pulse loads. Still, never shimmering.
class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final block = scheme.surfaceContainerHigh;
    Widget bar(double width, [double height = 14]) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: block,
        borderRadius: BorderRadius.circular(8),
      ),
    );
    Widget card(bool photo) => Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(VibeRadius.surface),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: block, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [bar(120), const SizedBox(height: 8), bar(80, 10)],
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (photo)
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: block,
                borderRadius: BorderRadius.circular(22),
              ),
            )
          else ...[
            bar(double.infinity),
            const SizedBox(height: 8),
            bar(220),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                width: 76,
                height: 40,
                decoration: BoxDecoration(
                  color: block,
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 76,
                height: 40,
                decoration: BoxDecoration(
                  color: block,
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return Semantics(
      label: 'Loading your Pulse',
      child: ExcludeSemantics(
        child: Column(children: [card(true), card(false)]),
      ),
    );
  }
}

/// A feed with nothing in it yet, with two ways to change that.
class _QuietFeed extends StatelessWidget {
  final String mode;
  const _QuietFeed({required this.mode});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final yours = mode == 'following';
    return Container(
      key: const Key('feed-empty'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(VibeRadius.surface),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VibeArt(height: 150),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              yours ? 'Your Pulse is quiet 🌙' : 'Nothing public yet 🌱',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              yours
                  ? 'Follow a few people or drop something of your own.'
                  : 'Public posts from everyone show up here.',
              style: TextStyle(
                height: 1.5,
                fontSize: 14.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              _BigButton(
                key: const Key('feed-empty-share'),
                label: 'Share a post',
                icon: Icons.edit_note_rounded,
                onTap: () => context.push('/compose'),
              ),
              _BigButton(
                key: const Key('feed-empty-find'),
                label: 'Find people',
                icon: Icons.search_rounded,
                filled: false,
                onTap: () => context.push('/people'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;
  const _BigButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.filled = true,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = filled ? VibeColors.ink : scheme.onSurface;
    return PressScale(
      minHeight: 48,
      semanticLabel: label,
      onTap: onTap,
      child: Align(
        widthFactor: 1,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          decoration: BoxDecoration(
            color: filled ? VibeColors.lime : Colors.transparent,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: filled ? VibeColors.lime : scheme.outlineVariant,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: fg),
              const SizedBox(width: 8),
              // Wraps instead of overflowing at large text sizes.
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one create button: a lime pill that opens the create sheet and folds
/// down to a plain "+" while the feed scrolls away.
class HomeCreateButton extends StatelessWidget {
  final ValueNotifier<bool> extended;
  const HomeCreateButton({super.key, required this.extended});

  @override
  Widget build(BuildContext context) {
    final duration = VibeMotion.duration(context);
    return ValueListenableBuilder<bool>(
      valueListenable: extended,
      builder: (context, open, _) => Tooltip(
        message: 'Create',
        child: PressScale(
          key: const Key('home-create'),
          minHeight: 56,
          pressedScale: .94,
          semanticLabel: 'Create',
          semanticHint: 'Post, story, circle or moment',
          onTap: () => showCreateSheet(context),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: VibeColors.lime,
              borderRadius: BorderRadius.circular(100),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .2),
                  blurRadius: 20,
                  spreadRadius: -2,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: AnimatedSize(
              duration: duration,
              curve: Curves.easeOutBack,
              alignment: Alignment.centerRight,
              child: Container(
                height: 56,
                constraints: const BoxConstraints(minWidth: 56),
                padding: EdgeInsets.symmetric(horizontal: open ? 20 : 0),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.add_rounded,
                      size: 26,
                      color: VibeColors.ink,
                    ),
                    if (open) ...[
                      const SizedBox(width: 8),
                      const Text(
                        'Create',
                        style: TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: VibeColors.ink,
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
