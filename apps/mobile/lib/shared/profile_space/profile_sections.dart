import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/profile_labels.dart';
import '../../core/theme.dart';

/// An uppercase section label with an optional trailing action.
class ProfileSectionTitle extends StatelessWidget {
  final String title;
  final Color muted;
  final Widget? action;
  const ProfileSectionTitle(
    this.title, {
    super.key,
    required this.muted,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: action == null ? 12 : 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.7,
              fontWeight: FontWeight.w800,
              color: muted,
            ),
          ),
        ),
        ?action,
      ],
    ),
  );
}

/// Country, profession, pronouns, education and website rows.
class ProfileAbout extends StatelessWidget {
  final Profile profile;
  final bool isOwner;
  final VoidCallback? onEdit;
  final Color muted;
  const ProfileAbout({
    super.key,
    required this.profile,
    required this.isOwner,
    required this.onEdit,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final rows = <(IconData, String, bool)>[
      if (p.country != null && countryNames.containsKey(p.country))
        (Icons.public_rounded, countryNames[p.country]!, false),
      if (p.profession.isNotEmpty)
        (Icons.work_outline_rounded, p.profession, true),
      if (p.pronouns.isNotEmpty)
        (Icons.person_outline_rounded, p.pronouns, false),
      if (p.education.isNotEmpty) (Icons.school_outlined, p.education, false),
      if (p.websiteUrl != null) (Icons.link_rounded, p.websiteUrl!, false),
    ];
    if (rows.isEmpty && !isOwner) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProfileSectionTitle(
          isOwner ? 'ABOUT ME' : 'ABOUT',
          muted: muted,
          action: isOwner
              ? TextButton(
                  onPressed: onEdit,
                  child: const Text(
                    'EDIT',
                    style: TextStyle(fontSize: 10, letterSpacing: 1),
                  ),
                )
              : null,
        ),
        if (rows.isEmpty)
          Text(
            'A few details, a little more you.',
            style: TextStyle(fontSize: 13, height: 1.5, color: muted),
          ),
        for (final (icon, value, editable) in rows)
          if (isOwner && editable)
            InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: _AboutRow(icon, value, muted, edit: true),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _AboutRow(icon, value, muted),
            ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  final IconData icon;
  final String value;
  final Color muted;
  final bool edit;
  const _AboutRow(this.icon, this.value, this.muted, {this.edit = false});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: muted),
      const SizedBox(width: 10),
      Expanded(
        child: Text(value, style: const TextStyle(fontSize: 13, height: 1.5)),
      ),
      if (edit) Icon(Icons.edit_outlined, size: 13, color: muted),
    ],
  );
}

/// Interest chips, or a prompt for an owner who has none yet.
class ProfileInterests extends StatelessWidget {
  final Profile profile;
  final bool isOwner;
  final VoidCallback? onEdit;
  final Color accent, muted;
  final bool dark;
  const ProfileInterests({
    super.key,
    required this.profile,
    required this.isOwner,
    required this.onEdit,
    required this.accent,
    required this.muted,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    final interests = profile.interests;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProfileSectionTitle(
          isOwner ? 'MY INTERESTS' : 'INTERESTS',
          muted: muted,
          action: isOwner
              ? IconButton(
                  tooltip: 'Edit interests',
                  onPressed: onEdit,
                  icon: const Icon(Icons.add_rounded, size: 20),
                )
              : null,
        ),
        if (interests.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < interests.length; i++)
                _InterestChip(interests[i], i, dark, accent),
            ],
          )
        else
          Text(
            'What are you into?',
            style: TextStyle(fontSize: 13, height: 1.5, color: muted),
          ),
      ],
    );
  }
}

class _InterestChip extends StatelessWidget {
  final String name;
  final int index;
  final bool dark;
  final Color accent;
  const _InterestChip(this.name, this.index, this.dark, this.accent);

  @override
  Widget build(BuildContext context) {
    final color = [
      accent,
      VibeColors.lilac,
      const Color(0xff9bded6),
    ][index % 3];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .09 : .25),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 12,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Spoken languages with their proficiency level.
class ProfileLanguages extends StatelessWidget {
  final List<ProfileLanguage> languages;
  final Color muted;
  const ProfileLanguages({
    super.key,
    required this.languages,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ProfileSectionTitle('LANGUAGES', muted: muted),
      Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          for (final language in languages)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: languageLabel(language.code),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (language.level.isNotEmpty)
                    TextSpan(
                      text:
                          ' · ${languageLevels[language.level] ?? 'Not specified'}',
                      style: TextStyle(color: muted),
                    ),
                ],
              ),
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
        ],
      ),
    ],
  );
}
