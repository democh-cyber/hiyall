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
  bool preview = false,
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
        preview: preview,
      ),
    ),
  ),
);

class PeopleFilterScreen extends StatefulWidget {
  final PeopleFilters? initial;
  final Profile? ownProfile;
  final bool preview;
  const PeopleFilterScreen({
    super.key,
    this.initial,
    this.ownProfile,
    this.preview = false,
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
  bool get hasFilters =>
      interests.isNotEmpty ||
      languages.isNotEmpty ||
      vibe != null ||
      country != null;

  // The owner's own languages come first, then common ones, then any picked
  // through search so every selection stays visible as a pill.
  List<String> get languagePills => {
    ...?widget.ownProfile?.languages.map((l) => l.code.toLowerCase()),
    'en',
    'hi',
    'ko',
    'ja',
    'es',
    'fr',
    ...languages,
  }.toList();

  @override
  void initState() {
    super.initState();
    final start = widget.initial;
    interests.addAll(start?.interests ?? []);
    languages.addAll(start?.languages ?? []);
    country = start == null || start.country.isEmpty ? null : start.country;
    vibe = start == null || start.vibe.isEmpty ? null : start.vibe;
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

  Widget section(String title, {String? count}) => Padding(
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
        if (count != null)
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
                        const Expanded(
                          child: Text(
                            'Filters',
                            style: TextStyle(
                              fontFamily: 'SpaceGrotesk',
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -.6,
                            ),
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
                    if (widget.preview)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: VibeColors.lilac.withValues(
                            alpha: theme.brightness == Brightness.dark
                                ? .09
                                : .35,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          'DESIGN PREVIEW\nTry a temporary filter draft. Live people search is not connected. Nothing here is saved.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    section('From'),
                    pills([
                      _Pill(
                        label: 'Anywhere',
                        selected: country == null,
                        onTap: () => change(() => country = null),
                      ),
                      _Pill(
                        label: country == null
                            ? 'Choose country'
                            : countryNames[country] ?? country!,
                        icon: country == null ? Icons.add_rounded : null,
                        selected: country != null,
                        onTap: () => choose(isCountry: true),
                      ),
                    ]),
                    section(
                      'Speaks',
                      count: languages.isEmpty
                          ? null
                          : '${languages.length} selected',
                    ),
                    pills([
                      _Pill(
                        label: 'Any language',
                        selected: languages.isEmpty,
                        onTap: () => change(languages.clear),
                      ),
                      for (final code in languagePills)
                        _Pill(
                          label: languageLabel(code),
                          selected: languages.contains(code),
                          onTap:
                              languages.length >= 10 &&
                                  !languages.contains(code)
                              ? null
                              : () => change(
                                  () => languages.contains(code)
                                      ? languages.remove(code)
                                      : languages.add(code),
                                ),
                        ),
                      _Pill(
                        label: 'More languages',
                        icon: Icons.search_rounded,
                        selected: false,
                        onTap: () => choose(isCountry: false),
                      ),
                    ]),
                    section(
                      'Into',
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
                      'Filters only match what people chose to show publicly. They apply to this search and aren’t saved.',
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
                          child: const Text('Reset'),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: widget.preview
                                ? null
                                : () => Navigator.of(context).pop(
                                    PeopleFilters(
                                      interests: interests,
                                      languages: languages,
                                      country: country ?? '',
                                      vibe: vibe ?? '',
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
                            child: Text(
                              widget.preview
                                  ? 'Search unavailable in preview'
                                  : 'Show people',
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

class _Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;
  const _Pill({
    required this.label,
    this.icon,
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
                    if (icon != null) ...[
                      Icon(icon, size: 16, color: foreground),
                      const SizedBox(width: 6),
                    ],
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
