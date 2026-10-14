import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/discovery.dart';
import '../core/location_service.dart';
import '../core/location_sync.dart';
import '../core/state.dart';
import '../core/surprise.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_link.dart';
import '../shared/press_scale.dart';
import 'discover_header.dart';
import 'discover_menu.dart';
import 'discover_person.dart';
import 'discover_states.dart';
import 'nearby_optin.dart';
import 'nearby_setting.dart';
import 'people_filters.dart';
import 'safety.dart';
import 'say_hi.dart';
import 'say_hi_ui.dart';

export 'discover_person.dart' show countryLabel, distanceLabel;

/// The filters of the people list, kept while the member moves between the
/// docked screens, and cleared when the account changes.
class DiscoverFilters extends Notifier<PeopleFilters> {
  @override
  PeopleFilters build() => PeopleFilters();
  void set(PeopleFilters value) => state = value;
}

final discoverFiltersProvider =
    NotifierProvider<DiscoverFilters, PeopleFilters>(DiscoverFilters.new);

/// Standalone entry to the same people list used on Discover.
class FindPeopleScreen extends StatelessWidget {
  const FindPeopleScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Find people')),
    body: const SafeArea(top: false, child: PeopleDiscovery()),
  );
}

class PeopleDiscovery extends ConsumerStatefulWidget {
  const PeopleDiscovery({super.key});
  @override
  ConsumerState<PeopleDiscovery> createState() => _PeopleDiscoveryState();
}

class _Category {
  final String label, id;
  final PeopleFilters preset;
  const _Category(this.id, this.label, this.preset);
  bool matches(PeopleFilters f) => f.sameAs(preset);
}

class _PeopleDiscoveryState extends ConsumerState<PeopleDiscovery> {
  late PeopleFilters filters = ref.read(discoverFiltersProvider);
  List<Profile> people = [];
  String? cursor, error;
  bool loading = false, searched = false;

  /// "My surroundings" was chosen but the server has no position for the
  /// member yet (permission refused, or the first read hasn't finished).
  bool needsLocation = false;

  /// Nearby is chosen but "Show me in Nearby" is off: nothing is read or
  /// shown until the person agrees in the explainer.
  bool nearbyOff = false;

  /// The position was already read once for this search, so a second
  /// LOCATION_NOT_SHARED shows the explanation instead of looping.
  bool locationTried = false;
  int generation = 0;
  Future<void>? _inFlight;

  /// The people of the very first page animate in once; later pages and
  /// searches just appear.
  Set<String> entrance = {};
  bool entranceDone = false;

  // Surprise card.
  SurpriseStatus surpriseStatus = SurpriseStatus.ready;
  String? lastSurprise;

  @override
  void initState() {
    super.initState();
    // Discover opens on everyone who opted in; filters narrow from there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(sayHiControllerProvider.notifier).reset();
      search();
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> search({bool more = false}) => _inFlight = _search(more: more);

  Future<void> _search({bool more = false}) async {
    // A new search supersedes one in flight; only pagination waits its turn.
    if (more && (loading || cursor == null)) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    final run = ++generation;
    var restart = false, readLocation = false;
    setState(() {
      loading = true;
      error = null;
      needsLocation = false;
      nearbyOff = false;
      searched = true;
      if (!more) {
        people = [];
        cursor = null;
      }
    });
    try {
      final List<Profile> page;
      final String? next;
      if (filters.nearby) {
        final result = await ref
            .read(apiProvider)
            .nearby(session, filters: filters, cursor: more ? cursor : null);
        page = result.items;
        next = result.nextCursor;
      } else {
        final data = await ref
            .read(apiProvider)
            .searchPeople(
              session,
              filters.toJson(cursor: more ? cursor : null),
            );
        page = (data['items'] as List)
            .map(
              (item) =>
                  Profile.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList();
        next = data['nextCursor'] as String?;
      }
      if (!mounted ||
          run != generation ||
          ref.read(sessionProvider).asData?.value != session) {
        return;
      }
      setState(() {
        final existing = people.map((p) => p.userId).toSet();
        people = [
          ...people,
          ...page.where((p) => !existing.contains(p.userId)),
        ];
        cursor = next;
        locationTried = false;
        if (!entranceDone) {
          entranceDone = true;
          entrance = {for (final p in page.take(8)) p.userId};
        }
      });
    } on ApiFailure catch (failure) {
      if (mounted && run == generation) {
        setState(() {
          if (failure.code == 'NEARBY_OFF') {
            nearbyOff = true;
          } else if (failure.code == 'LOCATION_NOT_SHARED') {
            // Already opted in (the stored area expired): read it again once.
            if (locationTried) {
              needsLocation = true;
            } else {
              locationTried = true;
              readLocation = true;
            }
          } else if (more && failure.code == 'INVALID_CURSOR') {
            // The page marker expired; start over rather than resend it.
            cursor = null;
            restart = true;
          } else {
            error = failure.message;
          }
        });
      }
    } catch (_) {
      if (mounted && run == generation) {
        setState(
          () => error =
              'Your people are taking a little longer to load. Try again.',
        );
      }
    } finally {
      if (mounted && run == generation) setState(() => loading = false);
    }
    if (restart && mounted && run == generation) await search();
    if (readLocation && mounted && run == generation) await retryLocation();
  }

  /// "Show me in Nearby": explainer first, then the switch and one position.
  Future<void> enableNearby() async {
    await turnOnNearby(context, ref);
    ref.invalidate(nearbyStatusProvider);
    if (mounted) {
      locationTried = true;
      search();
    }
  }

  Future<void> editFilters() async {
    var minor = false;
    try {
      minor = (await ref.read(nearbyStatusProvider.future)).minor;
    } catch (_) {}
    if (!mounted) return;
    final selected = await showPeopleFilters(
      context,
      initial: filters,
      ownProfile: ref.read(profileProvider).asData?.value,
      hideAgeGender: minor,
    );
    if (!mounted || selected == null) return;
    applyVisibleFilters(selected);
  }

  void applyVisibleFilters(PeopleFilters next) {
    setState(() => filters = next);
    ref.read(discoverFiltersProvider.notifier).set(next);
    search();
  }

  /// Reads the position again (after the person allowed it in their device
  /// settings, say) and repeats the search.
  Future<void> retryLocation() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    // Read before awaiting: the screen may be gone when the position arrives.
    final problem = ref.read(locationProblemProvider.notifier);
    final api = ref.read(apiProvider);
    final locator = ref.read(locationServiceProvider);
    try {
      final fix = await locator.current();
      await api.shareLocation(session, fix.latitude, fix.longitude);
      problem.set(null);
    } on LocationFailure catch (failure) {
      problem.set(failure.problem);
    } catch (_) {
      // The search below reports whatever is still wrong.
    }
    if (mounted) search();
  }

  // The categories are genuine shortcuts built from the owner's own public
  // profile, plus Online and Nearby, which are filters the server applies.
  List<_Category> categories(Profile? own) => [
    _Category('everyone', 'Everyone', PeopleFilters()),
    _Category('online', 'Online', PeopleFilters(online: true)),
    if (own != null && own.currentVibe.isNotEmpty)
      _Category('vibe', 'Same vibe', PeopleFilters(vibe: own.currentVibe)),
    if (own != null && own.interests.isNotEmpty)
      _Category(
        'interests',
        'Interests',
        PeopleFilters(interests: own.interests.take(10)),
      ),
    if (own != null && own.languages.isNotEmpty)
      _Category(
        'languages',
        'Languages',
        PeopleFilters(
          languages: own.languages
              .map((l) => l.code.toLowerCase())
              .toSet()
              .take(10),
        ),
      ),
    _Category('nearby', 'Nearby', PeopleFilters(nearby: true)),
  ];

  Future<void> open(Profile person) async {
    final session = ref.read(sessionProvider).asData?.value;
    final api = ref.read(apiProvider);
    await openPerson(context, person.userId);
    if (!mounted || session == null) return;
    // Keep the list and scroll position; only drop the row if the person was
    // blocked or became unavailable while their profile was open.
    try {
      await api.otherProfile(session, person.userId);
    } on ApiFailure catch (failure) {
      if (mounted && (failure.status == 404 || failure.status == 403)) {
        setState(
          () => people = [
            for (final p in people)
              if (p.userId != person.userId) p,
          ],
        );
      }
    } catch (_) {
      // Offline: leave the row; the next search settles it.
    }
  }

  // ---------------------------------------------------------- Row menu

  void _drop(String userId) {
    setState(
      () => people = [
        for (final p in people)
          if (p.userId != userId) p,
      ],
    );
  }

  /// The long press (or "More options") of a row: View profile, Report, Block,
  /// by the same handlers as the profile and conversation menus. The person
  /// leaves the list at once after a block or a report that blocked, and only
  /// after the server said so.
  Future<void> more(Profile person) async {
    final choice = await showPersonMenu(context, person);
    if (!mounted || choice == null) return;
    switch (choice) {
      case PersonMenuChoice.profile:
        await open(person);
      case PersonMenuChoice.report:
        final receipt = await showReportSheet(
          context,
          ref,
          targetType: 'user',
          targetId: person.userId,
          name: person.displayName,
        );
        if (mounted && (receipt?.blocked ?? false)) {
          ref.invalidate(otherProfileProvider(person.userId));
          _drop(person.userId);
        }
      case PersonMenuChoice.block:
        final blocked = await blockAccount(
          context,
          ref,
          userId: person.userId,
          name: person.displayName,
        );
        if (mounted && blocked) _drop(person.userId);
    }
  }

  // ------------------------------------------------------------ Surprise

  /// People the viewer already follows or chats with, best effort: a failure
  /// here only means the pick may be someone familiar.
  Future<Set<String>> knownPeople(Session session) async {
    final known = <String>{};
    try {
      final page = await ref
          .read(apiProvider)
          .connections(session, 'following');
      known.addAll(page.items.map((c) => c.user.userId));
    } catch (_) {}
    return known;
  }

  /// "Surprise me": opens the profile of a person picked at random from the
  /// loaded results (more are loaded first when there are few). It never starts
  /// a chat; see `SurpriseCard` and `core/surprise.dart`.
  Future<void> surprise() async {
    if (surpriseStatus == SurpriseStatus.loading) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    final random = ref.read(surpriseRandomProvider);
    setState(() => surpriseStatus = SurpriseStatus.loading);
    try {
      await _inFlight;
      if (!mounted) return;
      // An empty list may only be empty because it was loaded a while ago.
      if (people.isEmpty) await search();
      var pages = 0;
      while (mounted &&
          people.length < surpriseMinPool &&
          cursor != null &&
          error == null &&
          pages < surpriseMaxPages) {
        pages++;
        await search(more: true);
      }
      if (!mounted) return;
      if (people.isEmpty && error != null) {
        setState(() => surpriseStatus = SurpriseStatus.error);
        return;
      }
      final pick = pickSurprise(
        people,
        last: lastSurprise,
        known: await knownPeople(session),
        random: random,
      );
      if (!mounted) return;
      if (pick == null) {
        setState(() => surpriseStatus = SurpriseStatus.nothing);
        return;
      }
      lastSurprise = pick.userId;
      setState(() => surpriseStatus = SurpriseStatus.ready);
      await open(pick);
    } catch (_) {
      if (mounted) setState(() => surpriseStatus = SurpriseStatus.error);
    }
  }

  // --------------------------------------------------------------- Build

  Widget empty() {
    final onlyOnline =
        filters.online && filters.sameAs(PeopleFilters(online: true));
    if (onlyOnline) {
      return DiscoveryEmptyState(
        title: 'Nobody’s online right now',
        body: 'Check back in a bit, or see everyone.',
        primaryLabel: 'Show everyone',
        onPrimary: () => applyVisibleFilters(PeopleFilters()),
      );
    }
    if (filters.isEmpty) {
      return DiscoveryEmptyState(
        body: 'Check back soon, or refresh to look again.',
        primaryLabel: 'Refresh',
        onPrimary: search,
      );
    }
    return DiscoveryEmptyState(
      body: filters.nearby
          ? 'Nobody nearby right now. Try another filter or explore more people.'
          : 'Try another filter or explore more people.',
      primaryLabel: 'Clear filters',
      onPrimary: () => applyVisibleFilters(PeopleFilters()),
      secondaryLabel: 'Adjust filters',
      onSecondary: editFilters,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (previous, next) {
      if (previous?.asData?.value != next.asData?.value) {
        ref.read(discoverFiltersProvider.notifier).set(PeopleFilters());
        setState(() {
          generation++;
          people = [];
          filters = PeopleFilters();
          cursor = error = null;
          searched = loading = false;
          entranceDone = false;
          entrance = {};
          surpriseStatus = SurpriseStatus.ready;
          lastSurprise = null;
        });
        if (next.asData?.value != null) search();
      }
    });
    final own = ref.watch(profileProvider).asData?.value;
    final cats = categories(own);
    final chipSelected = cats.any((c) => c.matches(filters));
    final active = chipSelected ? 0 : filters.count;
    final showEmpty =
        searched &&
        !loading &&
        error == null &&
        !needsLocation &&
        !nearbyOff &&
        people.isEmpty;
    return SayHiEffects(
      child: Material(
        type: MaterialType.transparency,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Stack(
              children: [
                Positioned.fill(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      await search();
                    },
                    child: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      key: const Key('discovery-results-scroll'),
                      slivers: [
                        SliverToBoxAdapter(
                          child: SurpriseCard(
                            status: surpriseStatus,
                            onSurprise: surprise,
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: DiscoveryExploreRow(
                            activeCount: active,
                            onFilters: editFilters,
                            onReset: () => applyVisibleFilters(PeopleFilters()),
                          ),
                        ),
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: DiscoveryChipsHeader([
                            for (final c in cats)
                              DiscoveryCategory(
                                label: c.label,
                                key: Key('chip-${c.id}'),
                                selected: c.matches(filters),
                                onTap: () {
                                  if (!c.matches(filters)) {
                                    applyVisibleFilters(c.preset);
                                  }
                                },
                              ),
                          ]),
                        ),
                        if (nearbyOff)
                          SliverToBoxAdapter(
                            child: NearbyOptInCard(onEnable: enableNearby),
                          ),
                        if (needsLocation)
                          SliverToBoxAdapter(
                            child: _NeedsLocation(
                              problem: ref.watch(locationProblemProvider),
                              onRetry: retryLocation,
                              onSettings: (problem) => ref
                                  .read(locationServiceProvider)
                                  .openSettings(problem),
                            ),
                          ),
                        if (error != null)
                          SliverToBoxAdapter(
                            child: DiscoveryErrorCard(
                              message: error!,
                              onRetry: () => search(
                                more: people.isNotEmpty && cursor != null,
                              ),
                            ),
                          ),
                        if (showEmpty) SliverToBoxAdapter(child: empty()),
                        if (loading && people.isEmpty || !searched)
                          const SliverToBoxAdapter(
                            child: DiscoveryLoadingState(),
                          ),
                        SliverList.builder(
                          itemCount: people.length,
                          itemBuilder: (context, i) {
                            final person = people[i];
                            Widget tile = DiscoverPersonTile(
                              person: person,
                              sayHi: SayHiSlot(
                                person: person,
                                onTap: () => sayHiTap(
                                  context,
                                  ref,
                                  person,
                                  openProfile: () => open(person),
                                ),
                              ),
                              note: SayHiNote(userId: person.userId),
                              languagesFocus: filters.languages.isNotEmpty,
                              showDivider: i < people.length - 1,
                              onOpen: () => open(person),
                              onMore: () => more(person),
                            );
                            if (entrance.contains(person.userId)) {
                              tile = StaggerIn(index: i, child: tile);
                            }
                            return KeyedSubtree(
                              key: ValueKey(person.userId),
                              child: tile,
                            );
                          },
                        ),
                        if (loading && people.isNotEmpty)
                          const SliverToBoxAdapter(
                            child: DiscoveryPagingLoader(),
                          ),
                        if (cursor != null && !loading && error == null)
                          SliverToBoxAdapter(
                            child: DiscoveryMoreButton(
                              onTap: () => search(more: true),
                            ),
                          ),
                        if (devLoginEnabled)
                          const SliverToBoxAdapter(
                            child: InternalProfilePreview(),
                          ),
                        const SliverToBoxAdapter(child: SizedBox(height: 32)),
                      ],
                    ),
                  ),
                ),
                // "👋 sent to Mira": over the bottom of the list, never taking a tap.
                const PositionedDirectional(
                  start: 16,
                  end: 16,
                  bottom: 14,
                  child: SayHiToastHost(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Development-only shortcut to the other fixture account's profile.
class InternalProfilePreview extends ConsumerWidget {
  const InternalProfilePreview({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
    child: ExpansionTile(
      key: const Key('internal-profile-preview'),
      tilePadding: EdgeInsets.zero,
      title: Text(
        'Internal profile preview',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      children: [
        TextButton.icon(
          onPressed: () {
            final ownId = ref.read(sessionProvider).asData!.value!.userId;
            context.go(
              '/discover/person/${ownId == anjaliId ? nikoId : anjaliId}',
            );
          },
          icon: const Icon(Icons.person_outline_rounded, size: 18),
          label: Text(
            ref.watch(sessionProvider).asData?.value?.userId == anjaliId
                ? 'View Niko’s profile'
                : 'View Anjali’s profile',
          ),
        ),
      ],
    ),
  );
}

/// Shown instead of results when "My surroundings" is on but the device
/// position isn't available. The only way forward is the system's own
/// permission, so this explains it and offers a retry.
class _NeedsLocation extends StatelessWidget {
  final LocationProblem? problem;
  final VoidCallback onRetry;
  final void Function(LocationProblem problem) onSettings;
  const _NeedsLocation({
    required this.problem,
    required this.onRetry,
    required this.onSettings,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final blocked =
        problem == LocationProblem.deniedForever ||
        problem == LocationProblem.servicesOff;
    return Padding(
      key: const Key('needs-location'),
      padding: const EdgeInsets.fromLTRB(discoverPad, 24, discoverPad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'We can\u2019t see where you are yet.',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 22,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
              color: t.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            problem?.message ??
                'Allow location access for Hiyall to see people near you.',
            style: TextStyle(
              fontSize: 14.5,
              color: t.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('location-retry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
              if (blocked)
                OutlinedButton(
                  key: const Key('location-settings'),
                  onPressed: () => onSettings(problem!),
                  child: const Text('Open settings'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
