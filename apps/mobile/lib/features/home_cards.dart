import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/activity_state.dart';
import '../core/api.dart';
import '../core/discovery.dart';
import '../core/home_prefs.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/person_avatar.dart';
import '../shared/person_link.dart';
import '../shared/press_scale.dart';
import '../shared/story_canvas.dart';
import '../shared/widgets.dart';
import 'live_sync.dart';

/// A short, unfiltered first page of Discover: the same opted-in members the
/// Discover tab would show, so Home never widens who can be found. Kept for the
/// session; pull-to-refresh or a new sign-in reloads it.
final homeSuggestionsProvider = FutureProvider.autoDispose<List<Profile>>(
  (ref) async {
    final session = requireSession(ref);
    // Suggestions change slowly; don't re-query on every tab switch.
    ref.keepAlive();
    final data = await ref
        .watch(apiProvider)
        .searchPeople(session, PeopleFilters().toJson());
    return [
      for (final item in data['items'] as List)
        Profile.fromJson(Map<String, dynamic>.from(item as Map)),
    ].where((p) => p.userId != session.userId).take(10).toList();
  },
  // Suggestions are a nicety: a failed load stays quiet until the next pull to
  // refresh instead of retrying in the background.
  retry: (_, _) => null,
);

/// What an unfinished profile is still missing, in the order worth fixing.
List<String> missingProfileParts(Profile p) => [
  if (p.bio.trim().isEmpty) 'Bio',
  if (p.headline.trim().isEmpty) 'Headline',
  if (p.currentVibe.trim().isEmpty) 'Current vibe',
  if (p.interests.isEmpty) 'Interests',
  if (p.languages.isEmpty) 'Languages',
  if (p.pronouns.trim().isEmpty) 'Pronouns',
];

const profilePartCount = 6;

/// The most text growth a card on Home keeps. Past this the words ellipsize
/// instead of the card growing, since a swipeable row has one fixed height.
const homeCardTextScale = 1.3;

double _scaleOf(BuildContext context) =>
    MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: homeCardTextScale)
        .scale(1);

/// A small uppercase-free section title with an optional action on the right.
class HomeHeading extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;
  const HomeHeading(
    this.title, {
    super.key,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontFamily: 'SpaceGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 18,
                letterSpacing: -.4,
              ),
            ),
          ),
        ),
        if (action != null)
          PressScale(
            minHeight: 48,
            onTap: onAction,
            semanticLabel: '$action, $title',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Align(
                alignment: Alignment.center,
                widthFactor: 1,
                child: Text(
                  action!,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A rounded pill that reads as a button: ink on a pastel card, or an outline.
class _PillButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback? onTap;
  final IconData? icon;
  const _PillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.filled = true,
    this.icon,
  });
  @override
  Widget build(BuildContext context) => PressScale(
    minHeight: 48,
    onTap: onTap,
    semanticLabel: label,
    child: Align(
      child: Container(
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: filled ? VibeColors.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: filled
                ? VibeColors.ink
                : VibeColors.ink.withValues(alpha: .55),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 17,
                color: filled ? VibeColors.lime : VibeColors.ink,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: filled ? VibeColors.lime : VibeColors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The pastel, slightly glossy base every "For you" card shares.
class _Sticker extends StatelessWidget {
  final Color color;
  final Widget child;
  const _Sticker({required this.color, required this.child});
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(VibeRadius.surface),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(color, Colors.white, .28)!, color],
      ),
    ),
    child: DefaultTextStyle.merge(
      style: const TextStyle(color: VibeColors.ink),
      child: child,
    ),
  );
}

/// Everything that is waiting on this person, as one row of cards that is
/// there only while something needs them: friend and follow requests, unread
/// chats, and activity they have not seen. Nothing waiting, nothing shown.
class HomeForYou extends ConsumerWidget {
  /// In the wide layout's side rail the row lines up with the rail's own edge.
  final bool rail;
  final double topGap;
  const HomeForYou({super.key, this.rail = false, this.topGap = 0});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(activityProvider).asData?.value;
    final unreadChats = ref.watch(chatUnreadProvider);
    final requests = [
      for (final i in activity?.items ?? const <Map<String, dynamic>>[])
        if (isPendingRequest(i)) i,
    ];
    // A request already has its own card; only count what is left over.
    final unreadRequests = requests.where((r) => r['readAt'] == null).length;
    final otherActivity = math.max(0, (activity?.unread ?? 0) - unreadRequests);
    const shown = 5;
    final cards = <Widget Function()>[
      for (final r in requests.take(shown)) () => _RequestCard(item: r),
      if (requests.length > shown)
        () => _CountCard(
          key: const Key('home-more-requests'),
          color: VibeColors.pink,
          emoji: '💌',
          title: '${requests.length - shown} more waiting',
          cta: 'See all',
          onTap: () => context.go('/notifications'),
        ),
      if (unreadChats > 0)
        () => _CountCard(
          key: const Key('home-card-chats'),
          color: VibeColors.mint,
          emoji: '💬',
          title: unreadChats == 1
              ? '1 chat waiting 💬'
              : '$unreadChats chats waiting 💬',
          cta: 'Open chats',
          onTap: () => context.go('/chats'),
        ),
      if (otherActivity > 0)
        () => _CountCard(
          key: const Key('home-card-activity'),
          color: VibeColors.peach,
          emoji: '⚡',
          title: '$otherActivity new activity',
          cta: 'See what’s up',
          onTap: () => context.go('/notifications'),
        ),
    ];
    final scale = _scaleOf(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedSize(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: cards.isEmpty
          ? const SizedBox(width: double.infinity)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: topGap),
                HomeHeading(
                  'For you',
                  padding: EdgeInsets.symmetric(horizontal: rail ? 0 : 20),
                ),
                const SizedBox(height: 10),
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: homeCardTextScale,
                  child: SnapRow(
                    key: const Key('home-for-you'),
                    gutter: rail ? 0 : 16,
                    count: cards.length,
                    height: 92 + math.max(44, 41 * scale),
                    cardWidth: 292,
                    itemBuilder: (context, i) => cards[i](),
                  ),
                ),
              ],
            ),
    );
  }
}

class _RequestCard extends ConsumerWidget {
  final Map<String, dynamic> item;
  const _RequestCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actor = (item['actors'] as List).first as Map;
    final name = ((actor['displayName'] as String?)?.trim().isNotEmpty ?? false)
        ? (actor['displayName'] as String).trim()
        : '@${actor['username'] ?? ''}';
    final friend = item['type'] == 'friend_request';
    final id = item['notificationId'];
    final userId = actor['userId'] as String;
    Future<void> respond(bool accept) async {
      try {
        await ref.read(activityProvider.notifier).respond(item, accept);
      } catch (e) {
        if (context.mounted) showMessage(context, e.toString());
      }
    }

    return _Sticker(
      color: friend ? VibeColors.pink : VibeColors.lilac,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  PressScale(
                    borderRadius: BorderRadius.circular(100),
                    semanticLabel: 'Open $name’s profile',
                    onTap: () => openPerson(context, userId),
                    child: PersonAvatar(
                      name: name,
                      avatarUrl: actor['avatarUrl'] as String?,
                      userId: userId,
                      radius: 22,
                      tint: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      friend
                          ? '$name wants to be friends 💚'
                          : '$name wants to follow you 👋',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 1.2,
                        letterSpacing: -.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _PillButton(
                    key: Key('home-accept-$id'),
                    label: 'Accept',
                    icon: Icons.check_rounded,
                    onTap: () => respond(true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _PillButton(
                    key: Key('home-decline-$id'),
                    label: 'Not now',
                    filled: false,
                    onTap: () => respond(false),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "2 chats waiting" or "5 new activity": a number worth a tap, and where it goes.
class _CountCard extends StatelessWidget {
  final Color color;
  final String emoji, title, cta;
  final VoidCallback onTap;
  const _CountCard({
    super.key,
    required this.color,
    required this.emoji,
    required this.title,
    required this.cta,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => PressScale(
    borderRadius: BorderRadius.circular(VibeRadius.surface),
    pressedScale: .97,
    semanticLabel: '$title. $cta',
    onTap: onTap,
    child: _Sticker(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 22)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        height: 1.15,
                        letterSpacing: -.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  Text(
                    cta,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A slim "Finish your profile · 3/6" pill. It opens the editor, can be put
/// away (and stays away on this device, for this account), and is gone once
/// every part is filled in.
class HomeProfileNudge extends ConsumerWidget {
  final bool rail;
  final double topGap;
  const HomeProfileNudge({super.key, this.rail = false, this.topGap = 0});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider.select((p) => p.value));
    final hidden = ref.watch(profileNudgeHiddenProvider);
    if (profile == null || hidden != false) return const SizedBox.shrink();
    final missing = missingProfileParts(profile);
    if (missing.isEmpty) return const SizedBox.shrink();
    final done = profilePartCount - missing.length;
    final scheme = Theme.of(context).colorScheme;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: homeCardTextScale,
      child: Padding(
        padding: EdgeInsets.fromLTRB(rail ? 0 : 16, topGap, rail ? 0 : 16, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Expanded(
                child: PressScale(
                  key: const Key('home-profile-nudge'),
                  minHeight: 52,
                  semanticLabel:
                      'Finish your profile, $done of $profilePartCount done. '
                      'Still missing: ${missing.take(3).join(', ')}.',
                  onTap: () => context.go('/profile/edit'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            value: done / profilePartCount,
                            strokeWidth: 4,
                            strokeCap: StrokeCap.round,
                            color: scheme.primary,
                            backgroundColor: scheme.outlineVariant,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Finish your profile · $done/$profilePartCount',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
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
              ),
              IconButton(
                key: const Key('home-profile-nudge-hide'),
                tooltip: 'Hide for now',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  overlayColor: Colors.transparent,
                ),
                onPressed: () =>
                    ref.read(profileNudgeHiddenProvider.notifier).hide(),
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "People you might vibe with": a snap carousel of members from Discover's
/// opted-in first page, with what you share and a Follow button.
class HomeSuggestions extends ConsumerWidget {
  final bool rail;
  const HomeSuggestions({super.key, this.rail = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(homeSuggestionsProvider).asData?.value;
    if (people == null || people.isEmpty) return const SizedBox.shrink();
    final mine = {
      ...?ref.watch(profileProvider.select((p) => p.value?.interests)),
    };
    final scale = _scaleOf(context);
    return Column(
      key: const Key('home-suggestions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HomeHeading(
          'People you might vibe with',
          action: 'See all',
          onAction: () => context.go('/discover'),
          padding: EdgeInsets.symmetric(horizontal: rail ? 0 : 20),
        ),
        const SizedBox(height: 10),
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: homeCardTextScale,
          child: SnapRow(
            gutter: rail ? 0 : 16,
            count: people.length,
            height: 212 + 44 * scale,
            cardWidth: 208,
            itemBuilder: (context, i) {
              final p = people[i];
              return _PersonCard(
                person: p,
                common: [
                  for (final s in p.interests)
                    if (mine.contains(s)) s,
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Each card gets one of the story backgrounds as its banner, picked from the
/// member's id so it is the same every time.
const _bandNames = [
  'sunset',
  'aurora',
  'bubblegum',
  'grape',
  'mango',
  'freshmint',
  'ocean',
];

StoryBackground _bandFor(String userId) => storyBackgroundFor(
  _bandNames[userId.codeUnits.fold(0, (a, b) => a + b) % _bandNames.length],
);

class _PersonCard extends StatelessWidget {
  final Profile person;
  final List<String> common;
  const _PersonCard({required this.person, required this.common});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final band = _bandFor(person.userId);
    final line = [person.currentVibe, person.headline, person.profession]
        .firstWhere(
          (s) => s.trim().isNotEmpty,
          orElse: () => '@${person.username}',
        );
    final chip = common.isNotEmpty
        ? '${common.length} in common'
        : (person.interests.isNotEmpty ? person.interests.first : null);
    return PressScale(
      key: Key('home-person-${person.userId}'),
      borderRadius: BorderRadius.circular(VibeRadius.surface),
      pressedScale: .97,
      semanticLabel: 'Open ${person.displayName}’s profile',
      onTap: () => openPerson(context, person.userId),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(VibeRadius.surface),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(VibeRadius.surface - 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 96,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: 64,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: band.colors,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 32,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 4),
                        ),
                        child: PersonAvatar(
                          name: person.displayName,
                          avatarUrl: person.avatarUrl,
                          userId: person.userId,
                          radius: 28,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        person.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                          letterSpacing: -.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (chip != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: common.isNotEmpty
                                ? VibeColors.lime.withValues(
                                    alpha: dark ? .2 : .55,
                                  )
                                : scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text(
                            chip,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      const Spacer(),
                      _FollowButton(person: person),
                    ],
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

class _FollowButton extends ConsumerStatefulWidget {
  final Profile person;
  const _FollowButton({required this.person});
  @override
  ConsumerState<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<_FollowButton> {
  late String state = widget.person.relationship?.following ?? 'none';
  bool busy = false;

  Future<void> follow() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (busy || session == null) return;
    setState(() => busy = true);
    try {
      final result = await ref
          .read(apiProvider)
          .follow(session, widget.person.userId);
      ref.invalidate(profileProvider);
      if (mounted) setState(() => state = result);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = widget.person.displayName;
    final done = state != 'none';
    final label = switch (state) {
      'active' => 'Following',
      'pending' => 'Requested',
      _ => 'Follow',
    };
    return PressScale(
      key: Key('home-follow-${widget.person.userId}'),
      minHeight: 48,
      semanticLabel: done ? '$label $name' : 'Follow $name',
      onTap: done || busy ? null : follow,
      child: Align(
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? Colors.transparent : VibeColors.lime,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: done ? scheme.outlineVariant : VibeColors.lime,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                done ? Icons.check_rounded : Icons.add_rounded,
                size: 18,
                color: done ? scheme.onSurfaceVariant : VibeColors.ink,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: done ? scheme.onSurfaceVariant : VibeColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
