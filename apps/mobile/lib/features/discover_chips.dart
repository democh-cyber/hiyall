import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/personality.dart';
import '../shared/language_chip.dart';
import '../shared/local_time_label.dart';
import '../shared/tag_chip.dart';
import 'discover_header.dart' show discoverPad;

/// What a Discover row shows besides the person's name and lines: their local time ("3:42 PM there", only when
/// they show it), up to [maxLanguages] language chips with the level meter and up to [maxTags] personality
/// chips. Each chip is the tag drill-down: tapping it opens Discover filtered by it. It sits under the row, not
/// inside the row's own tap area, so the row stays one control and the chips stay their own.
///
/// The clock inside is [LocalTimeLabel]: it ticks only while the row is on screen and stops when the lazily
/// built list drops the row, so nothing runs off screen.
class DiscoverRowExtras extends ConsumerWidget {
  final Profile person;
  const DiscoverRowExtras({super.key, required this.person});

  static const maxLanguages = 3, maxTags = 2;

  /// The languages a row shows: each once, in the order the person set them.
  static List<ProfileLanguage> languagesOf(Profile person) {
    final seen = <String>{};
    return [
      for (final l in person.languages)
        if (seen.add(l.code.toLowerCase())) l,
    ].take(maxLanguages).toList();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final languages = languagesOf(person);
    final tags = person.personalityTags.take(maxTags).toList();
    final time = person.localTime;
    if (languages.isEmpty && tags.isEmpty && time == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: discoverPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (time != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: KeyedSubtree(
                key: Key('local-time-${person.userId}'),
                child: LocalTimeLabel(time: time),
              ),
            ),
          if (languages.isNotEmpty || tags.isNotEmpty)
            // One line, scrolling sideways when there are more than fit, so a row stays short; every chip keeps a
            // 48 dp hit area.
            SizedBox(
              height: 48,
              child: ListView(
                key: Key('row-chips-${person.userId}'),
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                children: [
                  for (final l in languages)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Center(
                        child: LanguageChip(
                          key: Key('row-language-${person.userId}-${l.code}'),
                          language: l,
                          dense: true,
                          onTap: () =>
                              openDiscoverWith(context, ref, languageFilter(l)),
                        ),
                      ),
                    ),
                  for (final id in tags)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Center(
                        child: TagChip(
                          key: Key('row-tag-${person.userId}-$id'),
                          label: personalityTagLabel(id),
                          icon: personalityTagById(id)?.icon,
                          dense: true,
                          onTap: () => openDiscoverWith(
                            context,
                            ref,
                            personalityFilter(id),
                          ),
                        ),
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
