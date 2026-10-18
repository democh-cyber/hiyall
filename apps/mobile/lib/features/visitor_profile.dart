import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/profile_labels.dart';
import '../core/state.dart';
import '../shared/language_chip.dart';
import '../shared/local_time_label.dart';
import '../shared/person_avatar.dart';
import '../shared/presence_dot.dart';
import '../shared/profile_space/profile_details.dart';
import '../shared/profile_space/profile_gallery.dart';
import '../shared/profile_stats.dart';

/// Another member's profile, as opened from Discover: who they are, how to
/// connect, then a detailed profile and their posts. Everything shown comes
/// from the viewer-filtered profile the server returned.
class VisitorProfile extends ConsumerStatefulWidget {
  final Profile profile;

  /// Friend, follow and message controls.
  final Widget actions;
  final VoidCallback onBack;
  final VoidCallback? onOptions;

  /// Where each tappable stat leads, and a calm line under them (for example
  /// when this member's lists are not shared).
  final ProfileStatActions statActions;
  final String? statsNote;

  /// The Posts content, or null for the empty state.
  final Widget? Function(int tab) contentFor;
  const VisitorProfile({
    super.key,
    required this.profile,
    required this.actions,
    required this.onBack,
    required this.contentFor,
    this.onOptions,
    this.statActions = const {},
    this.statsNote,
  });
  @override
  ConsumerState<VisitorProfile> createState() => _VisitorProfileState();
}

class _VisitorProfileState extends ConsumerState<VisitorProfile> {
  int tab = 0;

  static String? genderLabel(String value) => switch (value) {
    'woman' => 'Woman',
    'man' => 'Man',
    'nonbinary' => 'Non-binary',
    _ => null,
  };

  Widget genderMark(String value) {
    final (icon, color) = switch (value) {
      'woman' => (Icons.female_rounded, const Color(0xffe0529c)),
      'man' => (Icons.male_rounded, const Color(0xff3b7be8)),
      _ => (Icons.transgender_rounded, const Color(0xff8a5cd6)),
    };
    return Semantics(
      label: genderLabel(value),
      child: Icon(icon, size: 22, color: color),
    );
  }

  String? get place {
    final p = widget.profile;
    final parts = [
      if (p.country != null && countryNames.containsKey(p.country))
        countryNames[p.country]!,
      if (p.region.isNotEmpty) p.region,
      if (p.city.isNotEmpty) p.city,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final scheme = Theme.of(context).colorScheme;
    final own = ref.watch(profileProvider).asData?.value;
    final mine = {
      for (final i in own?.interests ?? const <String>[]) i.toLowerCase(),
    };
    final shared = [
      for (final i in p.interests)
        if (mine.contains(i.toLowerCase())) i,
    ];
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            key: const Key('visitor-profile'),
            padding: const EdgeInsets.only(bottom: 120),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('visitor-back'),
                      tooltip: 'Back',
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const Spacer(),
                    if (widget.onOptions != null)
                      IconButton(
                        key: const Key('profile-options'),
                        tooltip: 'Profile options',
                        onPressed: widget.onOptions,
                        icon: const Icon(Icons.more_horiz_rounded),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: _Header(
                  profile: p,
                  gender: p.gender.isEmpty ? null : genderMark(p.gender),
                  place: place,
                ),
              ),
              if (p.photos.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: ProfileGalleryStrip(photos: p.photos),
                ),
              if (p.headline.isNotEmpty || p.bio.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (p.headline.isNotEmpty)
                        Text(
                          p.headline,
                          style: const TextStyle(
                            fontSize: 16,
                            height: 1.4,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      if (p.bio.isNotEmpty && p.bio != p.headline)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            p.bio,
                            style: TextStyle(
                              fontSize: 14.5,
                              height: 1.5,
                              color: scheme.onSurface.withValues(alpha: .85),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (p.socialStats != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                  child: ProfileStatsRow(
                    stats: p.socialStats!,
                    actions: widget.statActions,
                    note: widget.statsNote,
                    ink: scheme.onSurface,
                    muted: scheme.onSurfaceVariant,
                    labelSize: 13,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: widget.actions,
              ),
              if (p.visitorsVisible)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: RecentVisitorsEntry(userId: p.userId),
                ),
              const SizedBox(height: 22),
              _Tabs(selected: tab, onSelect: (i) => setState(() => tab = i)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                child: tab == 0
                    ? _Details(
                        profile: p,
                        place: place,
                        shared: shared,
                        hasOwn: own != null,
                      )
                    : _Posts(content: widget.contentFor(0)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Profile profile;
  final Widget? gender;
  final String? place;
  const _Header({
    required this.profile,
    required this.gender,
    required this.place,
  });

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              PersonAvatar(
                name: p.displayName,
                avatarUrl: p.avatarFor(96),
                userId: p.userId,
                radius: 48,
                initialStyle: const TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (p.country != null)
                PositionedDirectional(
                  end: -4,
                  top: -4,
                  child: Container(
                    key: const Key('visitor-country'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Text(
                      p.country!.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              if (p.online == true)
                PositionedDirectional(
                  end: 4,
                  bottom: 4,
                  child: PresenceDot(
                    key: Key('online-dot-${p.userId}'),
                    size: 18,
                    ringWidth: 3,
                    ringColor: scheme.surface,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      p.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.5,
                        height: 1.15,
                      ),
                    ),
                  ),
                  if (gender != null) ...[const SizedBox(width: 6), gender!],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '@${p.username}',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (p.languages.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    for (final l in p.languages.take(4))
                      _LanguageMark(language: l),
                  ],
                ),
              ],
              if (place != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.place_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        place!,
                        key: const Key('visitor-place-header'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Language code with the level meter; the level is in the semantics ("English, fluent") and in words in the
/// detailed profile.
class _LanguageMark extends StatelessWidget {
  final ProfileLanguage language;
  const _LanguageMark({required this.language});
  @override
  Widget build(BuildContext context) => Semantics(
    label: languageSemantics(language),
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          language.code.split('-').first.toUpperCase(),
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 5),
        LevelMeter(level: language.level, height: 10),
      ],
    ),
  );
}

/// Two icon tabs under the actions, as in the reference: details and posts.
class _Tabs extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  const _Tabs({required this.selected, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tab(int i, IconData icon, String label) => Expanded(
      child: Semantics(
        button: true,
        selected: selected == i,
        label: label,
        child: InkWell(
          key: Key('visitor-tab-$i'),
          onTap: () => onSelect(i),
          child: Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: selected == i ? 3 : 1,
                  color: selected == i
                      ? scheme.onSurface
                      : scheme.outlineVariant,
                ),
              ),
            ),
            child: Tooltip(
              message: label,
              child: Icon(
                icon,
                size: 26,
                color: selected == i
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
    return Row(
      children: [
        tab(0, Icons.badge_outlined, 'Detailed profile'),
        tab(1, Icons.grid_view_rounded, 'Posts'),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  final Profile profile;
  final String? place;
  final List<String> shared;
  final bool hasOwn;
  const _Details({
    required this.profile,
    required this.place,
    required this.shared,
    required this.hasOwn,
  });

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    Widget heading(String text, {String? trailing}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 10,
        runSpacing: 2,
        children: [
          Text(
            text,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          if (trailing != null)
            Text(
              trailing,
              key: const Key('visitor-in-common'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
        ],
      ),
    );
    Widget fact(String label, Widget value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          value,
        ],
      ),
    );
    Widget chip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
    final rows = <(IconData, String)>[
      if (p.profession.isNotEmpty) (Icons.work_outline_rounded, p.profession),
      if (p.education.isNotEmpty) (Icons.school_outlined, p.education),
      if (p.pronouns.isNotEmpty) (Icons.person_outline_rounded, p.pronouns),
      if (p.websiteUrl != null) (Icons.link_rounded, p.websiteUrl!),
    ];
    final facts = [
      if (p.age != null)
        fact(
          'Age',
          Text(
            '${p.age}',
            key: const Key('visitor-age'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
      if (place != null)
        fact(
          'Current location',
          Row(
            children: [
              Icon(Icons.place_rounded, size: 20, color: muted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  place!,
                  key: const Key('visitor-place'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
    final aboutMe = p.aboutMe.trim();
    final hometown = p.hometown.trim();
    final birthday = birthdayText(p.birthday);
    final empty =
        facts.isEmpty &&
        p.interests.isEmpty &&
        p.personalityTags.isEmpty &&
        p.currentVibe.isEmpty &&
        p.languages.isEmpty &&
        aboutMe.isEmpty &&
        hometown.isEmpty &&
        birthday == null &&
        p.localTime == null &&
        rows.isEmpty;
    if (empty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '${p.displayName} hasn’t added details yet.',
          key: const Key('visitor-empty-details'),
          style: TextStyle(height: 1.6, color: muted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Detailed profile',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: facts),
        ],
        if (aboutMe.isNotEmpty) ...[
          const SizedBox(height: 24),
          heading('About me'),
          Text(
            aboutMe,
            key: const Key('visitor-about-me'),
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
        ],
        if (hometown.isNotEmpty || p.localTime != null || birthday != null) ...[
          const SizedBox(height: 20),
          if (hometown.isNotEmpty)
            ProfileFactRow(
              key: const Key('visitor-hometown'),
              icon: Icons.home_outlined,
              label: 'From',
              value: hometown,
              muted: muted,
              fontSize: 14.5,
            ),
          if (p.localTime != null)
            Padding(
              key: const Key('visitor-local-time'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: LocalTimeLabel(time: p.localTime!, full: true),
            ),
          if (birthday != null)
            ProfileFactRow(
              key: const Key('visitor-birthday'),
              icon: Icons.cake_outlined,
              label: 'Birthday',
              value: birthday,
              muted: muted,
              fontSize: 14.5,
            ),
        ],
        if (p.interests.isNotEmpty) ...[
          const SizedBox(height: 28),
          Divider(color: scheme.outlineVariant, height: 1),
          const SizedBox(height: 22),
          heading(
            'Interests',
            trailing: shared.isEmpty ? null : '${shared.length} in common',
          ),
          // Shared interests first, with a check mark.
          InterestChips(interests: p.interests, shared: shared),
        ],
        if (p.personalityTags.isNotEmpty) ...[
          const SizedBox(height: 28),
          heading('Personality'),
          PersonalityChips(tags: p.personalityTags),
        ],
        if (p.currentVibe.isNotEmpty) ...[
          const SizedBox(height: 28),
          heading('Current vibe'),
          Wrap(children: [chip(p.currentVibe)]),
        ],
        if (p.languages.isNotEmpty) ...[
          const SizedBox(height: 28),
          heading('Languages'),
          ProfileLanguageChips(languages: p.languages),
        ],
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 28),
          for (final (icon, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      value,
                      style: const TextStyle(fontSize: 14.5, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _Posts extends StatelessWidget {
  final Widget? content;
  const _Posts({required this.content});
  @override
  Widget build(BuildContext context) =>
      content ??
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Nothing shared yet. Check back soon.',
          key: const Key('visitor-empty-posts'),
          style: TextStyle(
            height: 1.6,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
