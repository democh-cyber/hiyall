import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/profile_labels.dart';
import '../core/discovery.dart';
import '../core/api.dart';
import '../core/theme.dart';

// Prefer the shortest standard tag when the ISO inventory has aliases with
// the same display name; do not show duplicate English/Hindi/etc. choices.
final _languageOptions = () {
  final entries = languageNames.entries.toList()
    ..sort((a, b) => a.key.length.compareTo(b.key.length));
  final names = <String>{};
  return Map<String, String>.fromEntries(
    entries.where((e) => names.add(e.value)),
  );
}();

Future<PeopleFilters?> showPeopleFilters(
  BuildContext context, {
  PeopleFilters? initial,
  Profile? ownProfile,
}) => showModalBottomSheet<PeopleFilters>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => FractionallySizedBox(
    heightFactor: .92,
    child: ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: PeopleFilterScreen(initial: initial, ownProfile: ownProfile),
    ),
  ),
);

class PeopleFilterScreen extends StatefulWidget {
  final PeopleFilters? initial;
  final Profile? ownProfile;
  const PeopleFilterScreen({super.key, this.initial, this.ownProfile});

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
      (gender.isEmpty ? 0 : 1);

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
    ageLow = ageFloor;
    ageHigh = ageCeiling;
    gender = '';
  });

  Future<void> choose({required bool isCountry}) async {
    final result = await showDialog<Set<String>>(
      context: context,
      useSafeArea: false,
      builder: (_) => Dialog.fullscreen(
        child: _LabelPicker(
          title: isCountry ? 'Choose a country' : 'Choose languages',
          labels: isCountry ? countryNames : _languageOptions,
          selected: isCountry ? {?country} : languages,
          multiple: !isCountry,
        ),
      ),
    );
    if (!mounted || result == null) return;
    change(() {
      if (isCountry) {
        country = result.isEmpty ? null : result.first;
      } else {
        languages
          ..clear()
          ..addAll(result);
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
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 12, 0),
                child: Column(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              const Text(
                                'Filters',
                                style: TextStyle(
                                  fontFamily: 'SpaceGrotesk',
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.6,
                                ),
                              ),
                              if (activeCount > 0) ...[
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: VibeColors.lime,
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                  child: Text(
                                    '$activeCount on',
                                    key: const Key('filter-sheet-count'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: VibeColors.ink,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close filters',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  key: const Key('filter-content'),
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [
                    section('Right now'),
                    _SwitchRow(
                      key: const Key('filter-online'),
                      label: 'Online now',
                      value: 'Only people who are online and show it to you',
                      on: online,
                      onChanged: (v) => change(() => online = v),
                    ),
                    section('Country'),
                    _FilterRow(
                      label: 'Anywhere',
                      selected: country == null,
                      radio: true,
                      onTap: () => change(() => country = null),
                    ),
                    const SizedBox(height: 10),
                    _FilterRow(
                      label: 'Choose country',
                      value: country == null
                          ? null
                          : countryNames[country] ?? country!,
                      selected: country != null,
                      radio: true,
                      opensPicker: true,
                      onTap: () => choose(isCountry: true),
                    ),
                    section(
                      'Language',
                      action: TextButton(
                        onPressed: languages.isEmpty
                            ? null
                            : () => change(languages.clear),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        child: const Text('Any language'),
                      ),
                    ),
                    _FilterRow(
                      label: 'Choose languages',
                      value: languages.isEmpty
                          ? 'Search languages'
                          : languages.map(languageLabel).join(' · '),
                      selected: languages.isNotEmpty,
                      opensPicker: true,
                      onTap: () => choose(isCountry: false),
                    ),
                    section('Age'),
                    Text(
                      ageLabel,
                      key: const Key('filter-age-label'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTickMarkColor: Colors.transparent,
                        inactiveTickMarkColor: Colors.transparent,
                      ),
                      child: RangeSlider(
                        key: const Key('filter-age'),
                        min: ageFloor,
                        max: ageCeiling,
                        divisions: (ageCeiling - ageFloor).round(),
                        values: RangeValues(ageLow, ageHigh),
                        labels: RangeLabels(
                          '${ageLow.round()}',
                          ageHigh >= ageCeiling ? '60+' : '${ageHigh.round()}',
                        ),
                        onChanged: (range) => setState(() {
                          ageLow = range.start;
                          ageHigh = range.end;
                        }),
                      ),
                    ),
                    section('Location'),
                    _FilterRow(
                      key: const Key('filter-nearby'),
                      label: 'My surroundings',
                      value: 'People close to where you are, nearest first',
                      selected: nearby,
                      checkbox: true,
                      onTap: () => change(() => nearby = !nearby),
                    ),
                    section('Gender'),
                    for (final (value, label) in const [
                      ('', 'All'),
                      ('man', 'Man'),
                      ('woman', 'Woman'),
                      ('nonbinary', 'Non-binary'),
                    ]) ...[
                      _FilterRow(
                        key: Key(
                          'filter-gender-${value.isEmpty ? 'any' : value}',
                        ),
                        label: label,
                        selected: gender == value,
                        radio: true,
                        onTap: () => change(() => gender = value),
                      ),
                      const SizedBox(height: 10),
                    ],
                    section(
                      'Interests',
                      count: interests.isEmpty
                          ? null
                          : '${interests.length} selected',
                    ),
                    pills([
                      for (final topic in {...topics, ...interests})
                        _Pill(
                          label: topic,
                          selected: interests.contains(topic),
                          onTap:
                              interests.length >= 10 &&
                                  !interests.contains(topic)
                              ? null
                              : () => change(
                                  () => interests.contains(topic)
                                      ? interests.remove(topic)
                                      : interests.add(topic),
                                ),
                        ),
                    ]),
                    section('Vibe'),
                    pills([
                      for (final item in {...vibes, ?vibe})
                        _Pill(
                          label: item,
                          selected: vibe == item,
                          onTap: () =>
                              change(() => vibe = vibe == item ? null : item),
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
                  ],
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(top: BorderSide(color: scheme.outlineVariant)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      children: [
                        TextButton(
                          key: const Key('clear-active-filters'),
                          onPressed: hasFilters ? clear : null,
                          child: const Text('Reset all'),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.of(context).pop(
                              PeopleFilters(
                                interests: interests,
                                languages: languages,
                                country: country ?? '',
                                vibe: vibe ?? '',
                                nearby: nearby,
                                online: online,
                                ageMin: ageLow > ageFloor
                                    ? ageLow.round()
                                    : null,
                                ageMax: ageHigh < ageCeiling
                                    ? ageHigh.round()
                                    : null,
                                gender: gender,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              shape: const StadiumBorder(),
                              disabledBackgroundColor: VibeColors.lime
                                  .withValues(alpha: .35),
                              disabledForegroundColor: scheme.onSurface
                                  .withValues(alpha: .65),
                            ),
                            child: const Text(
                              'Show people',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
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

/// A row with a switch, for a setting that is simply on or off.
class _SwitchRow extends StatelessWidget {
  final String label, value;
  final bool on;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.on,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(14);
    return Semantics(
      toggled: on,
      label: label,
      hint: value,
      excludeSemantics: true,
      onTap: () => onChanged(!on),
      child: Material(
        color: on ? scheme.primary.withValues(alpha: .06) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: on
                ? scheme.primary.withValues(alpha: .55)
                : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: () => onChanged(!on),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: on ? scheme.primary : scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          value,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Switch(value: on, onChanged: onChanged),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final String label;
  final String? value;
  final bool selected, radio, opensPicker, checkbox;
  final VoidCallback onTap;
  const _FilterRow({
    super.key,
    required this.label,
    this.value,
    required this.selected,
    this.radio = false,
    this.opensPicker = false,
    this.checkbox = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurface;
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: .06)
            : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected
                ? scheme.primary.withValues(alpha: .55)
                : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  if (radio) ...[
                    Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: selected ? foreground : scheme.outlineVariant,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: foreground,
                          ),
                        ),
                        if (value != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            value!,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (checkbox) ...[
                    const SizedBox(width: 12),
                    Icon(
                      selected
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 24,
                      color: selected ? foreground : scheme.outlineVariant,
                    ),
                  ],
                  if (opensPicker) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 22,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onPrimary
        : onTap == null
        ? scheme.onSurfaceVariant.withValues(alpha: .5)
        : scheme.onSurface;
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      child: AnimatedContainer(
        duration: VibeMotion.duration(context),
        decoration: ShapeDecoration(
          color: selected ? scheme.primary : scheme.surface,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: foreground,
                        ),
                      ),
                    ),
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

class _LabelPicker extends StatefulWidget {
  final String title;
  final Map<String, String> labels;
  final Set<String> selected;
  final bool multiple;
  const _LabelPicker({
    required this.title,
    required this.labels,
    required this.selected,
    required this.multiple,
  });
  @override
  State<_LabelPicker> createState() => _LabelPickerState();
}

class _LabelPickerState extends State<_LabelPicker> {
  late final selected = {...widget.selected};
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries =
        widget.labels.entries
            .where(
              (e) => e.value.toLowerCase().contains(
                search.text.trim().toLowerCase(),
              ),
            )
            .toList()
          ..sort((a, b) => a.value.compareTo(b.value));
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: math.max(
          56,
          MediaQuery.textScalerOf(context).scale(18) * 2.8 + 16,
        ),
        leading: IconButton(
          tooltip: 'Cancel selection',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(widget.title, style: const TextStyle(fontSize: 18)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: widget.multiple
                          ? 'Search languages'
                          : 'Search countries',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () => setState(search.clear),
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(
                          child: Text('No matches. Try another name.'),
                        )
                      : ListView.builder(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final checked = selected.contains(entry.key);
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 4,
                              ),
                              title: Text(entry.value),
                              selected: checked,
                              trailing: Icon(
                                checked
                                    ? Icons.check_circle_rounded
                                    : Icons.circle_outlined,
                                color: checked
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                              ),
                              onTap:
                                  widget.multiple &&
                                      selected.length >= 10 &&
                                      !checked
                                  ? null
                                  : () {
                                      HapticFeedback.selectionClick();
                                      if (widget.multiple) {
                                        setState(
                                          () => checked
                                              ? selected.remove(entry.key)
                                              : selected.add(entry.key),
                                        );
                                      } else {
                                        Navigator.of(context).pop({entry.key});
                                      }
                                    },
                            );
                          },
                        ),
                ),
                if (widget.multiple)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(selected),
                        child: Text(
                          'Use ${selected.length} ${selected.length == 1 ? 'language' : 'languages'}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
