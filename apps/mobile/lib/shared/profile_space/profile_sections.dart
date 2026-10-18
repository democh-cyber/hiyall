import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/profile_labels.dart';
import '../local_time_label.dart';
import 'profile_details.dart';

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

/// About me, hometown, local time, birthday, country, profession, pronouns, education and website. Everything
/// but the country and the website is shown only when the server sent it for this viewer.
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
    final aboutMe = p.aboutMe.trim();
    final hometown = p.hometown.trim();
    final birthday = birthdayText(p.birthday);
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
    final nothing =
        rows.isEmpty &&
        aboutMe.isEmpty &&
        hometown.isEmpty &&
        birthday == null &&
        p.localTime == null;
    if (nothing && !isOwner) return const SizedBox.shrink();
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
        if (nothing)
          Text(
            'A few details, a little more you.',
            style: TextStyle(fontSize: 13, height: 1.5, color: muted),
          ),
        if (aboutMe.isNotEmpty)
          Padding(
            key: const Key('profile-about-me'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              aboutMe,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
        if (hometown.isNotEmpty)
          ProfileFactRow(
            key: const Key('profile-hometown'),
            icon: Icons.home_outlined,
            label: 'From',
            value: hometown,
            muted: muted,
          ),
        if (p.localTime != null)
          Padding(
            key: const Key('profile-local-time'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: LocalTimeLabel(time: p.localTime!, full: true),
            ),
          ),
        if (birthday != null)
          ProfileFactRow(
            key: const Key('profile-birthday'),
            icon: Icons.cake_outlined,
            label: 'Birthday',
            value: birthday,
            muted: muted,
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

/// Interest chips (each opens Discover filtered by it), or a prompt for an owner who has none yet.
class ProfileInterests extends StatelessWidget {
  final Profile profile;
  final bool isOwner;
  final VoidCallback? onEdit;
  final Color muted;
  const ProfileInterests({
    super.key,
    required this.profile,
    required this.isOwner,
    required this.onEdit,
    required this.muted,
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
          InterestChips(interests: interests)
        else
          Text(
            'What are you into?',
            style: TextStyle(fontSize: 13, height: 1.5, color: muted),
          ),
      ],
    );
  }
}

/// Personality tags as chips; nothing at all when there are none.
class ProfilePersonality extends StatelessWidget {
  final List<String> tags;
  final Color muted;
  const ProfilePersonality({
    super.key,
    required this.tags,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ProfileSectionTitle('PERSONALITY', muted: muted),
      PersonalityChips(tags: tags),
    ],
  );
}

/// Spoken languages: a chip each, with the level in words.
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
      ProfileLanguageChips(languages: languages),
    ],
  );
}
