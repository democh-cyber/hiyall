import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/api.dart';
import '../../core/profile_labels.dart';
import '../chat_tokens.dart';
import '../language_chip.dart';
import '../press_scale.dart';
import '../tag_chip.dart';

/// "May 17" for a birthday, or null when the month and day do not make a date. Only ever the month and the day:
/// the server never sends the year and this never makes up an age from it. A leap year stands in so 29 February
/// reads right.
String? birthdayText(Birthday? birthday) {
  if (birthday == null) return null;
  final month = birthday.month, day = birthday.day;
  if (month < 1 || month > 12 || day < 1) return null;
  if (day > DateUtils.getDaysInMonth(2000, month)) return null;
  return DateFormat.MMMMd().format(DateTime(2000, month, day));
}

/// What a profile says about a member's languages: each one as a chip (tap to find people who speak it) followed
/// by the level in words, so the level never depends on the meter alone.
class ProfileLanguageChips extends ConsumerWidget {
  final List<ProfileLanguage> languages;
  const ProfileLanguageChips({super.key, required this.languages});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ChatTokens.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final language in languages)
          Wrap(
            key: Key('profile-language-${language.code}'),
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              LanguageChip(
                language: language,
                onTap: () =>
                    openDiscoverWith(context, ref, languageFilter(language)),
              ),
              if (language.level >= minLanguageLevel &&
                  language.level <= maxLanguageLevel)
                ExcludeSemantics(
                  child: Text(
                    languageLevelName(language.level),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: t.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Interests as chips that open Discover filtered by the interest. Interests [shared] with the viewer come
/// first and carry a check mark and "in common" for screen readers, so they stand out without colour alone.
class InterestChips extends ConsumerWidget {
  final List<String> interests;
  final List<String> shared;
  const InterestChips({
    super.key,
    required this.interests,
    this.shared = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lower = {for (final s in shared) s.toLowerCase()};
    bool isShared(String i) => lower.contains(i.toLowerCase());
    Widget chip(String i, {required bool common}) => TagChip(
      key: Key('interest-$i'),
      label: i,
      icon: common ? Icons.check_rounded : null,
      semanticLabel: common ? '$i, in common' : i,
      onTap: () => openDiscoverWith(context, ref, interestFilter(i)),
    );
    return ChipWrap(
      children: [
        for (final i in interests)
          if (isShared(i)) chip(i, common: true),
        for (final i in interests)
          if (!isShared(i)) chip(i, common: false),
      ],
    );
  }
}

/// Personality tags as chips that open Discover filtered by the tag.
class PersonalityChips extends ConsumerWidget {
  final List<String> tags;
  const PersonalityChips({super.key, required this.tags});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ChipWrap(
    children: [
      for (final id in tags)
        TagChip.personality(
          id,
          onTap: () => openDiscoverWith(context, ref, personalityFilter(id)),
        ),
    ],
  );
}

/// One quiet line of a profile: an icon, a label and a value ("From · Lisbon", "Birthday · May 17").
class ProfileFactRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color? muted;
  final double fontSize;
  const ProfileFactRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.muted,
    this.fontSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    final color = muted ?? ChatTokens.of(context).textTertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        container: true,
        label: '$label $value',
        child: ExcludeSemantics(
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$label · ',
                        style: TextStyle(color: color),
                      ),
                      TextSpan(
                        text: value,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  style: TextStyle(fontSize: fontSize, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How long a visit stays on the list, and the line that says so on a profile and above the list itself.
const recentVisitorsNote =
    'People who open this profile show up here for 30 days.';

/// The way into a member's recent visitors, on a profile that shares them (never on your own: you have the
/// visitors list). It says plainly that opening the profile adds you, so nobody is listed by surprise.
class RecentVisitorsEntry extends StatelessWidget {
  final String userId;
  const RecentVisitorsEntry({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return PressScale(
      key: const Key('recent-visitors-entry'),
      borderRadius: BorderRadius.circular(16),
      minHeight: 56,
      semanticLabel: 'Recent visitors. $recentVisitorsNote',
      semanticHint: 'Opens the list',
      onTap: () => GoRouter.of(context).push('/person/$userId/visitors'),
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: t.elevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.hairline),
        ),
        child: Row(
          children: [
            Icon(Icons.visibility_outlined, size: 22, color: t.accent),
            const SizedBox(width: 12),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recent visitors',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      recentVisitorsNote,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: t.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Icon(
              Directionality.of(context) == TextDirection.rtl
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              color: t.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
