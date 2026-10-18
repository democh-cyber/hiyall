import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/discovery.dart';
import '../core/personality.dart';
import '../features/discovery.dart' show discoverFiltersProvider;
import 'chat_tokens.dart';
import 'press_scale.dart';

/// An interest or a personality tag as a chip. With [onTap] it is the tag drill-down: tapping opens Discover
/// filtered by it. At least 48 dp high to hit.
class TagChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  /// The words a screen reader says; the label by default.
  final String? semanticLabel;
  final bool dense;
  const TagChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.semanticLabel,
    this.dense = false,
  });

  factory TagChip.interest(String interest, {VoidCallback? onTap}) =>
      TagChip(label: interest, onTap: onTap);

  factory TagChip.personality(String id, {VoidCallback? onTap}) => TagChip(
    label: personalityTagLabel(id),
    icon: personalityTagById(id)?.icon,
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final chip = Container(
      constraints: BoxConstraints(minHeight: dense ? 28 : 34),
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: dense ? 10 : 13,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: t.elevated,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: t.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 14 : 16, color: t.accent),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? 12.5 : 13.5,
                fontWeight: FontWeight.w600,
                color: t.text,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return Semantics(
        label: semanticLabel ?? label,
        container: true,
        child: ExcludeSemantics(child: chip),
      );
    }
    return PressScale(
      onTap: onTap,
      minHeight: 48,
      semanticLabel: semanticLabel ?? label,
      semanticHint: 'Find people with this in common',
      child: ExcludeSemantics(child: chip),
    );
  }
}

/// The tag drill-down: puts [filters] on Discover and goes there. Discover reads them as soon as it shows (and
/// right away if it is already open), runs the search and lets the member change or reset them. From a profile
/// that sits above the dock the route is replaced by the docked Discover tab.
void openDiscoverWith(
  BuildContext context,
  WidgetRef ref,
  PeopleFilters filters,
) {
  ref.read(discoverFiltersProvider.notifier).set(filters);
  GoRouter.of(context).go('/discover');
}

/// Filters for one interest, one personality tag or one language (at any level).
PeopleFilters interestFilter(String interest) =>
    PeopleFilters(interests: [interest]);
PeopleFilters personalityFilter(String id) =>
    PeopleFilters(personalityTags: [id]);
PeopleFilters languageFilter(ProfileLanguage language) =>
    PeopleFilters(languages: [language.code.toLowerCase()]);

/// A wrapped row of chips with the right spacing, one place for the profile, the editor and a row.
class ChipWrap extends StatelessWidget {
  final List<Widget> children;
  final double spacing;
  const ChipWrap({super.key, required this.children, this.spacing = 8});
  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: spacing, runSpacing: spacing / 2, children: children);
}
