import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/discovery.dart';
import '../core/profile_labels.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'people_filters.dart';

String countryLabel(String? code) =>
    countryNames[code?.toUpperCase()] ?? 'Other country';

class PeopleDiscovery extends ConsumerStatefulWidget {
  const PeopleDiscovery({super.key});
  @override
  ConsumerState<PeopleDiscovery> createState() => _PeopleDiscoveryState();
}

class _PeopleDiscoveryState extends ConsumerState<PeopleDiscovery> {
  PeopleFilters filters = PeopleFilters();
  List<Profile> people = [];
  String? cursor, error;
  bool loading = false, searched = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    // Discover opens on everyone who opted in; filters narrow from there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) search();
    });
  }

  Future<void> search({bool more = false}) async {
    // A new search supersedes one in flight; only pagination waits its turn.
    if (more && (loading || cursor == null)) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    final run = ++generation;
    setState(() {
      loading = true;
      error = null;
      searched = true;
      if (!more) {
        people = [];
        cursor = null;
      }
    });
    try {
      final data = await ref
          .read(apiProvider)
          .searchPeople(session, filters.toJson(cursor: more ? cursor : null));
      if (!mounted ||
          run != generation ||
          ref.read(sessionProvider).asData?.value != session) {
        return;
      }
      final page = (data['items'] as List)
          .map(
            (item) => Profile.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
      setState(() {
        final existing = people.map((p) => p.userId).toSet();
        people = [
          ...people,
          ...page.where((p) => !existing.contains(p.userId)),
        ];
        cursor = data['nextCursor'] as String?;
      });
    } on ApiFailure catch (failure) {
      if (mounted && run == generation) {
        setState(() => error = failure.message);
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
  }

  Future<void> editFilters() async {
    final selected = await showPeopleFilters(
      context,
      initial: filters,
      ownProfile: ref.read(profileProvider).asData?.value,
    );
    if (!mounted || selected == null) return;
    applyVisibleFilters(selected);
  }

  void applyVisibleFilters(PeopleFilters next) {
    setState(() => filters = next);
    search();
  }

  PeopleFilters without({
    bool country = false,
    String? language,
    String? interest,
    bool vibe = false,
  }) => PeopleFilters(
    interests: filters.interests.where((v) => v != interest),
    languages: filters.languages.where((v) => v != language),
    country: country ? '' : filters.country,
    vibe: vibe ? '' : filters.vibe,
  );

  List<_AppliedSelection> get selectedFilters => [
    if (filters.country.isNotEmpty)
      _AppliedSelection(
        id: 'country-${filters.country}',
        label: countryLabel(filters.country),
        category: 'country',
        remove: () => applyVisibleFilters(without(country: true)),
      ),
    for (final code in filters.languages)
      _AppliedSelection(
        id: 'language-$code',
        label: languageLabel(code),
        category: 'language',
        remove: () => applyVisibleFilters(without(language: code)),
      ),
    for (final interest in filters.interests)
      _AppliedSelection(
        id: 'interest-$interest',
        label: interest,
        category: 'interest',
        remove: () => applyVisibleFilters(without(interest: interest)),
      ),
    if (filters.vibe.isNotEmpty)
      _AppliedSelection(
        id: 'vibe-${filters.vibe}',
        label: filters.vibe,
        category: 'vibe',
        remove: () => applyVisibleFilters(without(vibe: true)),
      ),
  ];

  // Tabs are genuine shortcuts built from the owner's own public profile.
  List<_DiscoverTab> tabs(Profile? own) => [
    _DiscoverTab('Everyone', PeopleFilters()),
    if (own != null && own.currentVibe.isNotEmpty)
      _DiscoverTab('Same vibe', PeopleFilters(vibe: own.currentVibe)),
    if (own != null && own.interests.isNotEmpty)
      _DiscoverTab(
        'Your interests',
        PeopleFilters(interests: own.interests.take(10)),
      ),
    if (own != null && own.languages.isNotEmpty)
      _DiscoverTab(
        'Your languages',
        PeopleFilters(
          languages: own.languages
              .map((l) => l.code.toLowerCase())
              .toSet()
              .take(10),
        ),
      ),
  ];

  List<String> explanations(Profile person) => [
    for (final interest in person.interests)
      if (filters.interests.any(
        (v) => v.toLowerCase() == interest.toLowerCase(),
      ))
        'Into $interest',
    for (final language in person.languages)
      if (filters.languages.contains(language.code.toLowerCase()))
        'Speaks ${languageLabel(language.code)}',
    if (filters.vibe.isNotEmpty &&
        filters.vibe.toLowerCase() == person.currentVibe.toLowerCase())
      'Vibe: ${person.currentVibe}',
  ];

  Future<void> open(Profile person) async {
    await context.push('/discover/person/${person.userId}');
    // Re-query on return; changed privacy/blocks must not leave stale rows.
    if (mounted) search();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (previous, next) {
      if (previous?.asData?.value != next.asData?.value) {
        setState(() {
          generation++;
          people = [];
          filters = PeopleFilters();
          cursor = error = null;
          searched = loading = false;
        });
        if (next.asData?.value != null) search();
      }
    });
    final own = ref.watch(profileProvider).asData?.value;
    final privacy = ref.watch(privacyProvider).asData?.value;
    final scheme = Theme.of(context).colorScheme;
    final selection = selectedFilters;
    final header = _DiscoverHeader(
      scaler: MediaQuery.textScalerOf(context),
      direction: Directionality.of(context),
      tabs: tabs(own),
      filters: filters,
      selection: selection,
      onTab: applyVisibleFilters,
      onEdit: editFilters,
      onClear: () => applyVisibleFilters(PeopleFilters()),
    );
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: CustomScrollView(
            key: const Key('discovery-results-scroll'),
            slivers: [
              SliverPersistentHeader(pinned: true, delegate: header),
              if (privacy != null && !privacy.flag('discoverable'))
                SliverToBoxAdapter(
                  child: _HiddenNotice(
                    onTap: () => context.go('/profile/privacy'),
                  ),
                ),
              if (error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _DiscoveryError(message: error!),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () =>
                              search(more: people.isNotEmpty && cursor != null),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (searched && !loading && error == null && people.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 40, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your orbit is a little quiet.',
                          style: TextStyle(
                            fontFamily: 'SpaceGrotesk',
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          filters.isEmpty
                              ? 'Nobody has opted in here yet. Check back soon.'
                              : 'Try fewer filters or a different vibe.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (!filters.isEmpty) ...[
                              FilledButton(
                                onPressed: () =>
                                    applyVisibleFilters(PeopleFilters()),
                                child: const Text('Clear filters'),
                              ),
                              OutlinedButton(
                                onPressed: editFilters,
                                child: const Text('Adjust filters'),
                              ),
                            ] else
                              OutlinedButton(
                                onPressed: search,
                                child: const Text('Explore everyone'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              SliverList.builder(
                itemCount: people.length,
                itemBuilder: (context, i) => _ResultEntry(
                  key: ValueKey(people[i].userId),
                  child: _PersonRow(
                    person: people[i],
                    reasons: explanations(people[i]),
                    onTap: () => open(people[i]),
                  ),
                ),
              ),
              if (loading || !searched) const _PeopleSkeleton(),
              if (cursor != null && !loading && error == null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: OutlinedButton(
                      onPressed: () => search(more: true),
                      child: const Text('Explore more people'),
                    ),
                  ),
                ),
              if (devLoginEnabled)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: ExpansionTile(
                      key: const Key('internal-profile-preview'),
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        'Internal profile preview',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            final ownId = ref
                                .read(sessionProvider)
                                .asData!
                                .value!
                                .userId;
                            context.go(
                              '/discover/person/${ownId == anjaliId ? nikoId : anjaliId}',
                            );
                          },
                          icon: const Icon(
                            Icons.person_outline_rounded,
                            size: 18,
                          ),
                          label: Text(
                            ref.watch(sessionProvider).asData?.value?.userId ==
                                    anjaliId
                                ? 'View Niko’s profile'
                                : 'View Anjali’s profile',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ),
      ),
    );
  }
}

// Presentation metadata only; all values come from the applied PeopleFilters.
class _AppliedSelection {
  final String id, label, category;
  final VoidCallback remove;
  const _AppliedSelection({
    required this.id,
    required this.label,
    required this.category,
    required this.remove,
  });
}

class _DiscoverTab {
  final String label;
  final PeopleFilters preset;
  const _DiscoverTab(this.label, this.preset);
  bool matches(PeopleFilters f) =>
      f.country == preset.country &&
      f.vibe == preset.vibe &&
      _same(f.interests, preset.interests) &&
      _same(f.languages, preset.languages);
  static bool _same(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);
}

/// Title, shortcut tabs and the applied-filter row stay pinned above results.
class _DiscoverHeader extends SliverPersistentHeaderDelegate {
  final List<_DiscoverTab> tabs;
  final PeopleFilters filters;
  final List<_AppliedSelection> selection;
  final ValueChanged<PeopleFilters> onTab;
  final VoidCallback onEdit, onClear;
  late final double titleHeight, tabHeight, chipHeight, extent;

  _DiscoverHeader({
    required TextScaler scaler,
    required TextDirection direction,
    required this.tabs,
    required this.filters,
    required this.selection,
    required this.onTab,
    required this.onEdit,
    required this.onClear,
  }) {
    double line(String value, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textScaler: scaler,
        textDirection: direction,
        maxLines: 1,
      )..layout();
      final height = painter.height.ceilToDouble();
      painter.dispose();
      return height;
    }

    titleHeight = math.max(48, line('Discover', titleStyle) + 8);
    tabHeight = math.max(48, line('Everyone', tabStyle) + 20);
    chipHeight = math.max(48, line('Ag', chipStyle) + 24);
    extent = titleHeight + tabHeight + 12 + chipHeight + 12 + 1;
  }

  static const titleStyle = TextStyle(
    fontFamily: 'SpaceGrotesk',
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -1,
    height: 1.1,
  );
  static const tabStyle = TextStyle(
    fontFamily: 'Manrope',
    fontSize: 14,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );
  static const chipStyle = TextStyle(
    fontFamily: 'Manrope',
    fontSize: 12,
    fontWeight: FontWeight.w700,
    height: 1.3,
  );

  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: extent,
      child: Material(
        color: theme.scaffoldBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: titleHeight,
              child: const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text('Discover', maxLines: 1, style: titleStyle),
                ),
              ),
            ),
            SizedBox(
              height: tabHeight,
              child: ListView.separated(
                key: const Key('discover-tabs'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: tabs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final tab = tabs[i];
                  final selected = tab.matches(filters);
                  return Semantics(
                    selected: selected,
                    button: true,
                    child: InkWell(
                      onTap: selected ? null : () => onTab(tab.preset),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              width: 2,
                              color: selected
                                  ? scheme.onSurface
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Text(
                          tab.label,
                          maxLines: 1,
                          style: tabStyle.copyWith(
                            color: selected
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: 12),
            SizedBox(
              height: chipHeight,
              child: ListView(
                key: selection.isEmpty
                    ? null
                    : const Key('applied-filter-summary'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _FiltersButton(count: selection.length, onTap: onEdit),
                  for (final item in selection) ...[
                    const SizedBox(width: 8),
                    _AppliedFilterChip(item: item),
                  ],
                  if (selection.length > 1) ...[
                    const SizedBox(width: 4),
                    TextButton(
                      key: const Key('clear-applied-filters'),
                      onPressed: onClear,
                      child: const Text('Clear all', style: chipStyle),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_DiscoverHeader oldDelegate) => true;
}

class _FiltersButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _FiltersButton({required this.count, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Filter people',
      child: Material(
        color: scheme.surface,
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.tune_rounded, size: 16),
                const SizedBox(width: 6),
                const Text('Filters', style: _DiscoverHeader.chipStyle),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: VibeColors.lime,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '$count',
                      key: const Key('filter-count'),
                      style: _DiscoverHeader.chipStyle.copyWith(
                        color: VibeColors.ink,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppliedFilterChip extends StatelessWidget {
  final _AppliedSelection item;
  const _AppliedFilterChip({required this.item});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Remove ${item.category}: ${item.label}',
      excludeSemantics: true,
      child: Material(
        color: scheme.primary,
        shape: const StadiumBorder(),
        child: InkWell(
          key: ValueKey('applied-${item.id}'),
          customBorder: const StadiumBorder(),
          onTap: item.remove,
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _DiscoverHeader.chipStyle.copyWith(
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.close_rounded, size: 14, color: scheme.onPrimary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HiddenNotice extends StatelessWidget {
  final VoidCallback onTap;
  const _HiddenNotice({required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: VibeColors.lilac.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? .14 : .45,
        ),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.visibility_off_outlined, size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'You’re hidden from Discover',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    'Turn on',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _avatarTints = [
  VibeColors.lime,
  VibeColors.lilac,
  VibeColors.pink,
  VibeColors.mint,
  VibeColors.peach,
];

class _PersonRow extends StatelessWidget {
  final Profile person;
  final List<String> reasons;
  final VoidCallback onTap;
  const _PersonRow({
    required this.person,
    required this.reasons,
    required this.onTap,
  });

  String get blurb => [
    person.headline,
    person.bio,
    person.currentVibe,
  ].firstWhere((v) => v.isNotEmpty, orElse: () => '');

  // Screen readers get every public field; the row itself stays compact.
  String get description => [
    person.displayName,
    '@${person.username}',
    if (person.country != null) countryLabel(person.country),
    for (final l in person.languages)
      [
        languageLabel(l.code),
        if (languageLevels[l.level] case final level? when l.level.isNotEmpty)
          level,
      ].join(', '),
    if (person.headline.isNotEmpty) person.headline,
    if (person.bio.isNotEmpty && person.bio != person.headline) person.bio,
    if (person.interests.isNotEmpty) 'Into ${person.interests.join(', ')}',
    if (person.currentVibe.isNotEmpty) 'Vibe: ${person.currentVibe}',
    ...reasons,
  ].join('. ');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint =
        _avatarTints[person.userId.codeUnits.fold(0, (a, b) => a + b) %
            _avatarTints.length];
    return Semantics(
      button: true,
      label: description,
      hint: 'Opens profile',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: tint,
                      foregroundColor: VibeColors.ink,
                      child: Text(
                        person.displayName.characters.firstOrNull
                                ?.toUpperCase() ??
                            '?',
                        style: const TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (person.country != null)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Text(
                            person.country!.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: .4,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      person.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (person.languages.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 10,
                        runSpacing: 2,
                        children: [
                          for (final language in person.languages.take(3))
                            _LanguageLevel(language: language),
                        ],
                      ),
                    ],
                    if (blurb.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        blurb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (reasons.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        reasons.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.secondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: VibeColors.lime,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_outward_rounded,
                  size: 18,
                  color: VibeColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Language code plus up to three dots for the self-reported level.
class _LanguageLevel extends StatelessWidget {
  final ProfileLanguage language;
  const _LanguageLevel({required this.language});
  static const filled = {
    'basic': 1,
    'conversational': 2,
    'fluent': 3,
    'native': 3,
  };
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dots = filled[language.level];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          language.code.split('-').first.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (dots != null) ...[
          const SizedBox(width: 4),
          for (var i = 0; i < 3; i++)
            Container(
              width: 5,
              height: 5,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < dots
                    ? scheme.onSurface
                    : scheme.onSurface.withValues(alpha: .18),
              ),
            ),
        ],
      ],
    );
  }
}

class _ResultEntry extends StatelessWidget {
  final Widget child;
  const _ResultEntry({super.key, required this.child});
  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? child
      : TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 180),
          tween: Tween(begin: 0, end: 1),
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 4 * (1 - value)),
              child: child,
            ),
          ),
          child: child,
        );
}

class _DiscoveryError extends StatelessWidget {
  final String message;
  const _DiscoveryError({required this.message});
  @override
  Widget build(BuildContext context) {
    final connection =
        message == 'Could not connect. Check your connection and retry.';
    // Existing ApiFailure cannot distinguish offline from an unreachable service.
    // Keep authentication/eligibility/rate-limit copy instead of mislabeling it.
    final actionable =
        connection ||
        message.contains('eligibility') ||
        message.contains('session') ||
        message.contains('wait') ||
        message.contains('entries');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          connection
              ? 'Couldn’t connect.'
              : actionable
              ? 'A little pause.'
              : 'Something went wrong.',
          style: const TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          actionable
              ? message
              : 'Your people are taking a little longer to load.',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _PeopleSkeleton extends StatelessWidget {
  const _PeopleSkeleton();
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: .07);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return SliverToBoxAdapter(
      child: Semantics(
        label: 'Finding people',
        liveRegion: true,
        child: ExcludeSemantics(
          child: Column(
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            bar(120, 12),
                            const SizedBox(height: 8),
                            bar(60, 8),
                            const SizedBox(height: 8),
                            bar(double.infinity, 10),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
