import 'package:flutter/material.dart';

import '../core/discovery.dart';
import '../core/personality.dart';
import '../core/profile_labels.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import 'discover_header.dart' show discoverPad;

/// One filter that is on, as the member sees it in the summary under the category chips, with what the
/// selection becomes when it is removed.
class ActiveFilterItem {
  final String id, label;
  final IconData? icon;
  final PeopleFilters without;
  const ActiveFilterItem(this.id, this.label, this.without, {this.icon});
}

/// "Fluent or higher": the words for a minimum language level.
String minLevelLabel(int level) =>
    level >= maxLevelWord ? 'Native' : '${languageLevelName(level)} or higher';

/// The level from which the words say "Native" on their own.
const maxLevelWord = 6;

/// Every filter of [f] on its own, in the order the filters sheet shows them. Modes (Nearby, Possible matches)
/// are not listed: their chip says it.
List<ActiveFilterItem> activeFilterItems(PeopleFilters f) {
  if (f.possible) return const [];
  final items = <ActiveFilterItem>[];
  if (f.sameCountry) {
    items.add(
      ActiveFilterItem(
        'same-country',
        'Same country',
        f.copyWith(sameCountry: false),
        icon: Icons.flag_outlined,
      ),
    );
  }
  if (f.country.isNotEmpty) {
    items.add(
      ActiveFilterItem(
        'country',
        countryNames[f.country.toUpperCase()] ?? 'Other country',
        f.copyWith(country: ''),
      ),
    );
  }
  if (f.online) {
    items.add(
      ActiveFilterItem('online', 'Online now', f.copyWith(online: false)),
    );
  }
  for (final code in f.languages) {
    final rest = [
      for (final other in f.languages)
        if (other != code) other,
    ];
    items.add(
      ActiveFilterItem(
        'language-$code',
        languageLabel(code),
        f.copyWith(
          languages: rest,
          languageMinLevel: rest.isEmpty ? 0 : f.languageMinLevel,
        ),
      ),
    );
  }
  if (f.languageMinLevel > 0 && f.languages.isNotEmpty) {
    items.add(
      ActiveFilterItem(
        'level',
        minLevelLabel(f.languageMinLevel),
        f.copyWith(languageMinLevel: 0),
      ),
    );
  }
  for (final interest in f.interests) {
    items.add(
      ActiveFilterItem(
        'interest-$interest',
        interest,
        f.copyWith(
          interests: [
            for (final other in f.interests)
              if (other != interest) other,
          ],
        ),
      ),
    );
  }
  for (final id in f.personalityTags) {
    items.add(
      ActiveFilterItem(
        'tag-$id',
        personalityTagLabel(id),
        f.copyWith(
          personalityTags: [
            for (final other in f.personalityTags)
              if (other != id) other,
          ],
        ),
        icon: personalityTagById(id)?.icon,
      ),
    );
  }
  if (f.vibe.isNotEmpty) {
    items.add(ActiveFilterItem('vibe', f.vibe, f.copyWith(vibe: '')));
  }
  if (f.hasAge) {
    final low = f.ageMin ?? 13;
    items.add(
      ActiveFilterItem(
        'age',
        f.ageMax == null ? '$low and over' : '$low to ${f.ageMax} years old',
        f.copyWith(ageMin: () => null, ageMax: () => null),
      ),
    );
  }
  if (f.gender.isNotEmpty) {
    items.add(
      ActiveFilterItem('gender', switch (f.gender) {
        'man' => 'Man',
        'woman' => 'Woman',
        'nonbinary' => 'Non-binary',
        _ => f.gender,
      }, f.copyWith(gender: '')),
    );
  }
  if (f.nearby) {
    items.add(ActiveFilterItem('nearby', 'Nearby', f.copyWith(nearby: false)));
  }
  return items;
}

/// The filters that are on, as chips that each remove themselves (a drill-down from a tag shows the tag here).
/// Every chip is at least 48 dp high and one control for a screen reader: "English, remove filter".
class DiscoverActiveFilters extends StatelessWidget {
  final PeopleFilters filters;
  final ValueChanged<PeopleFilters> onChange;
  const DiscoverActiveFilters({
    super.key,
    required this.filters,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final items = activeFilterItems(filters);
    if (items.isEmpty) return const SizedBox.shrink();
    final t = ChatTokens.of(context);
    return Padding(
      key: const Key('discover-active-filters'),
      padding: const EdgeInsetsDirectional.fromSTEB(
        discoverPad,
        0,
        discoverPad,
        4,
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 0,
        children: [
          for (final item in items)
            PressScale(
              key: Key('active-filter-${item.id}'),
              onTap: () => onChange(item.without),
              minHeight: 48,
              semanticLabel: '${item.label}, remove filter',
              child: ExcludeSemantics(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 32),
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 8, 4),
                  decoration: BoxDecoration(
                    color: t.elevated,
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(color: t.accent.withValues(alpha: .6)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.icon != null) ...[
                        Icon(item.icon, size: 14, color: t.accent),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: t.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: t.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
