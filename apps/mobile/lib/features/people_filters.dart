import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/discovery.dart';
import '../core/personality.dart';
import '../core/profile_labels.dart';
import 'people_filters/age_range.dart';
import 'people_filters/filter_footer.dart';
import 'people_filters/filter_header.dart';
import 'people_filters/filter_rows.dart';
import 'people_filters/label_picker.dart';

Future<PeopleFilters?> showPeopleFilters(
  BuildContext context, {
  PeopleFilters? initial,
  Profile? ownProfile,
  bool hideAgeGender = false,
}) => showModalBottomSheet<PeopleFilters>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => FractionallySizedBox(
    heightFactor: .92,
    child: ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: PeopleFilterScreen(
        initial: initial,
        ownProfile: ownProfile,
        hideAgeGender: hideAgeGender,
      ),
    ),
  ),
);

class PeopleFilterScreen extends StatefulWidget {
  final PeopleFilters? initial;
  final Profile? ownProfile;

  /// Members under 18 have no age or gender filters (the server refuses them).
  final bool hideAgeGender;
  const PeopleFilterScreen({
    super.key,
    this.initial,
    this.ownProfile,
    this.hideAgeGender = false,
  });

  @override
  State<PeopleFilterScreen> createState() => _PeopleFilterScreenState();
}

class _PeopleFilterScreenState extends State<PeopleFilterScreen> {
  static const topics = [
    'Music',
    'Gaming',
    'Tech',
    'Photography',
    'Travel',
    'Art',
    'Books',
    'Movies',
    'Fitness',
    'Food',
    'Learning',
  ];
  static const vibes = [
    'Chill',
    'Creative',
    'Explorer',
    'Bookish',
    'Night owl',
    'Active',
  ];
  final interests = <String>{};
  final languages = <String>{};
  String? vibe, country;
  bool nearby = false;
  bool online = false;

  /// "Same country" and the lowest level wanted in the chosen languages (0 is any level).
  bool sameCountry = false;
  int minLevel = 0;
  final personality = <String>{};

  /// The level choices of the "Minimum level" selector: any, then conversational and up.
  static const levelChoices = [0, 3, 4, 5, 6];

  /// Whether the member has no country on their own profile, so "Same country" cannot work yet. Unknown (the
  /// profile has not loaded) counts as not missing: the server says so if it is.
  bool get countryMissing {
    final own = widget.ownProfile;
    return own != null && (own.country ?? '').isEmpty;
  }

  static const countryMissingWords = 'Add your country in your profile first';

  /// The slider runs from [ageFloor] to [ageCeiling]; the top stop means
  /// "and over", so it sends no upper limit.
  static const ageFloor = 13.0, ageCeiling = 60.0;
  double ageLow = ageFloor, ageHigh = ageCeiling;
  String gender = '';
  bool get ageActive => ageLow > ageFloor || ageHigh < ageCeiling;
  String get ageLabel {
    final low = ageLow.round();
    final high = ageHigh >= ageCeiling ? '60+' : '${ageHigh.round()}';
    return '$low to $high years old';
  }

  bool get hasFilters =>
      nearby ||
      online ||
      sameCountry ||
      personality.isNotEmpty ||
      minLevel > 0 ||
      ageActive ||
      gender.isNotEmpty ||
      interests.isNotEmpty ||
      languages.isNotEmpty ||
      vibe != null ||
      country != null;

  /// How many separate filters are on right now (the same count the Discover
  /// screen shows on its Filters button).
  int get activeCount =>
      interests.length +
      languages.length +
      (country == null ? 0 : 1) +
      (vibe == null ? 0 : 1) +
      (nearby ? 1 : 0) +
      (online ? 1 : 0) +
      (ageActive ? 1 : 0) +
      (gender.isEmpty ? 0 : 1) +
      personality.length +
      (minLevel > 0 && languages.isNotEmpty ? 1 : 0) +
      (sameCountry ? 1 : 0);

  @override
  void initState() {
    super.initState();
    final start = widget.initial;
    interests.addAll(start?.interests ?? []);
    languages.addAll(start?.languages ?? []);
    country = start == null || start.country.isEmpty ? null : start.country;
    vibe = start == null || start.vibe.isEmpty ? null : start.vibe;
    nearby = start?.nearby ?? false;
    online = start?.online ?? false;
    personality.addAll(start?.personalityTags ?? []);
    minLevel = levelChoices.contains(start?.languageMinLevel)
        ? start!.languageMinLevel
        : 0;
    sameCountry = (start?.sameCountry ?? false) && !countryMissing;
    ageLow = (start?.ageMin ?? ageFloor.round()).toDouble().clamp(
      ageFloor,
      ageCeiling,
    );
    ageHigh = (start?.ageMax ?? ageCeiling.round()).toDouble().clamp(
      ageFloor,
      ageCeiling,
    );
    gender = start?.gender ?? '';
  }

  void change(VoidCallback update) {
    HapticFeedback.selectionClick();
    setState(update);
  }

  void clear() => change(() {
    interests.clear();
    languages.clear();
    vibe = null;
    country = null;
    nearby = false;
    online = false;
    sameCountry = false;
    minLevel = 0;
    personality.clear();
    ageLow = ageFloor;
    ageHigh = ageCeiling;
    gender = '';
  });

  Future<void> choose({required bool isCountry}) async {
    final result = await showDialog<Set<String>>(
      context: context,
      useSafeArea: false,
      builder: (_) => Dialog.fullscreen(
        child: LabelPicker(
          title: isCountry ? 'Choose a country' : 'Choose languages',
          labels: isCountry ? countryNames : languageOptions,
          selected: isCountry ? {?country} : languages,
          multiple: !isCountry,
        ),
      ),
    );
    if (!mounted || result == null) return;
    change(() {
      if (isCountry) {
        country = result.isEmpty ? null : result.first;
        if (country != null) sameCountry = false;
      } else {
        languages
          ..clear()
          ..addAll(result);
        if (languages.isEmpty) minLevel = 0;
      }
    });
  }

  Widget section(String title, {String? count, Widget? action}) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -.3,
            ),
          ),
        ),
        if (action != null)
          action
        else if (count != null)
          Text(
            count,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    ),
  );

  Widget pills(List<Widget> children) =>
      Wrap(spacing: 8, runSpacing: 8, children: children);

  /// What Show people hands back to Discover.
  void apply() => Navigator.of(context).pop(
    PeopleFilters(
      interests: interests,
      languages: languages,
      country: country ?? '',
      vibe: vibe ?? '',
      nearby: nearby,
      online: online,
      languageMinLevel: languages.isEmpty ? 0 : minLevel,
      personalityTags: [
        for (final tag in personalityTags)
          if (personality.contains(tag.id)) tag.id,
        // An id this app version does not know stays, so a newer saved choice is not lost.
        for (final id in personality)
          if (personalityTagById(id) == null) id,
      ],
      sameCountry: sameCountry,
      ageMin: ageLow > ageFloor ? ageLow.round() : null,
      ageMax: ageHigh < ageCeiling ? ageHigh.round() : null,
      gender: gender,
    ),
  );

  List<Widget> sameCountryRow() => [
    const SizedBox(height: 16),
    SwitchRow(
      key: const Key('filter-same-country'),
      label: 'Same country',
      value: countryMissing
          ? countryMissingWords
          : 'Only people from the same country as you',
      on: sameCountry && !countryMissing,
      enabled: !countryMissing,
      onChanged: (v) => change(() {
        sameCountry = v;
        if (v) country = null;
      }),
    ),
  ];

  List<Widget> minLevelSection() => [
    section('Minimum level'),
    Text(
      'At least this level in one of the languages above',
      style: TextStyle(
        fontSize: 13,
        height: 1.4,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
    const SizedBox(height: 10),
    pills([
      for (final level in levelChoices)
        FilterPill(
          key: Key('filter-min-level-$level'),
          label: level == 0 ? 'Any level' : languageLevelName(level),
          selected: minLevel == level,
          onTap: () => change(() => minLevel = level),
        ),
    ]),
  ];

  List<Widget> personalitySection() => [
    section(
      'Personality',
      count: personality.isEmpty ? null : '${personality.length} selected',
    ),
    pills([
      for (final tag in personalityTags)
        FilterPill(
          key: Key('filter-tag-${tag.id}'),
          label: tag.label,
          icon: tag.icon,
          selected: personality.contains(tag.id),
          onTap: () => change(
            () => personality.contains(tag.id)
                ? personality.remove(tag.id)
                : personality.add(tag.id),
          ),
        ),
    ]),
  ];

  List<Widget> locationAndCountry() => [
    ...sameCountryRow(),
    section('Right now'),
    SwitchRow(
      key: const Key('filter-online'),
      label: 'Online now',
      value: 'Only people who are online and show it to you',
      on: online,
      onChanged: (v) => change(() => online = v),
    ),
    section('Country'),
    FilterRow(
      label: 'Anywhere',
      selected: country == null && !sameCountry,
      radio: true,
      onTap: () => change(() {
        country = null;
        sameCountry = false;
      }),
    ),
    const SizedBox(height: 10),
    FilterRow(
      label: 'Choose country',
      value: country == null ? null : countryNames[country] ?? country!,
      selected: country != null,
      radio: true,
      opensPicker: true,
      onTap: () => choose(isCountry: true),
    ),
    section(
      'Language',
      action: TextButton(
        onPressed: languages.isEmpty ? null : () => change(languages.clear),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: const Text('Any language'),
      ),
    ),
    FilterRow(
      label: 'Choose languages',
      value: languages.isEmpty
          ? 'Search languages'
          : languages.map(languageLabel).join(' · '),
      selected: languages.isNotEmpty,
      opensPicker: true,
      onTap: () => choose(isCountry: false),
    ),
    if (languages.isNotEmpty) ...minLevelSection(),
  ];

  List<Widget> ageSection() => [
    section('Age'),
    AgeRange(
      floor: ageFloor,
      ceiling: ageCeiling,
      low: ageLow,
      high: ageHigh,
      label: ageLabel,
      onChanged: (range) => setState(() {
        ageLow = range.start;
        ageHigh = range.end;
      }),
    ),
  ];

  List<Widget> genderSection() => [
    section('Gender'),
    for (final (value, label) in const [
      ('', 'All'),
      ('man', 'Man'),
      ('woman', 'Woman'),
      ('nonbinary', 'Non-binary'),
    ]) ...[
      FilterRow(
        key: Key('filter-gender-${value.isEmpty ? 'any' : value}'),
        label: label,
        selected: gender == value,
        radio: true,
        onTap: () => change(() => gender = value),
      ),
      const SizedBox(height: 10),
    ],
  ];

  List<Widget> interestsAndVibe(ColorScheme scheme) => [
    section(
      'Interests',
      count: interests.isEmpty ? null : '${interests.length} selected',
    ),
    pills([
      for (final topic in {...topics, ...interests})
        FilterPill(
          label: topic,
          selected: interests.contains(topic),
          onTap: interests.length >= 10 && !interests.contains(topic)
              ? null
              : () => change(
                  () => interests.contains(topic)
                      ? interests.remove(topic)
                      : interests.add(topic),
                ),
        ),
    ]),
    ...personalitySection(),
    section('Vibe'),
    pills([
      for (final item in {...vibes, ?vibe})
        FilterPill(
          label: item,
          selected: vibe == item,
          onTap: () => change(() => vibe = vibe == item ? null : item),
        ),
    ]),
    const SizedBox(height: 20),
    Text(
      'Filters only match what people chose to show publicly. Online now means active in the last couple of minutes.',
      style: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: scheme.onSurfaceVariant,
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              FilterHeader(activeCount: activeCount),
              Expanded(
                child: ListView(
                  key: const Key('filter-content'),
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [
                    ...locationAndCountry(),
                    if (!widget.hideAgeGender) ...ageSection(),
                    section('Location'),
                    FilterRow(
                      key: const Key('filter-nearby'),
                      label: 'My surroundings',
                      value: 'People close to where you are, nearest first',
                      selected: nearby,
                      checkbox: true,
                      onTap: () => change(() => nearby = !nearby),
                    ),
                    if (!widget.hideAgeGender) ...genderSection(),
                    ...interestsAndVibe(scheme),
                  ],
                ),
              ),
              FilterFooter(
                hasFilters: hasFilters,
                onClear: clear,
                onApply: apply,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
