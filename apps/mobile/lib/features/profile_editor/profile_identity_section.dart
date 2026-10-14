import 'package:flutter/material.dart';

import '../../core/profile_labels.dart';
import 'profile_form_widgets.dart';
import 'profile_label_picker.dart';

/// Display name, username, headline, bio and quote.
class ProfileIdentitySection extends StatelessWidget {
  final TextEditingController name, username, headline, bio, quote;
  final bool enabled;
  const ProfileIdentitySection({
    super.key,
    required this.name,
    required this.username,
    required this.headline,
    required this.bio,
    required this.quote,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ProfileHeading('Your identity'),
      ProfileTextField(
        name,
        'Display name',
        80,
        enabled: enabled,
        validator: (value) => value == null || value.trim().isEmpty
            ? 'Enter a display name.'
            : null,
      ),
      ProfileTextField(
        username,
        'Username',
        30,
        enabled: enabled,
        validator: (value) =>
            RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(value?.trim() ?? '')
            ? null
            : 'Use 3–30 lowercase letters, numbers or underscores.',
        prefix: '@',
      ),
      ProfileTextField(headline, 'Headline', 100, enabled: enabled),
      ProfileTextField(bio, 'Bio', 300, lines: 3, enabled: enabled),
      ProfileTextField(
        quote,
        'A little quote (optional)',
        160,
        lines: 2,
        enabled: enabled,
      ),
      const Text(
        'Your headline, bio and quote follow your profile visibility.',
        style: TextStyle(fontSize: 12, height: 1.6),
      ),
    ],
  );
}

/// Profession, pronouns, gender and country.
class ProfileAboutSection extends StatelessWidget {
  final TextEditingController profession, pronouns;
  final String gender;
  final String? country;
  final bool enabled;
  final ValueChanged<String> onGender;

  /// The chosen country code, or null when the person removed it.
  final ValueChanged<String?> onCountry;
  const ProfileAboutSection({
    super.key,
    required this.profession,
    required this.pronouns,
    required this.gender,
    required this.country,
    required this.enabled,
    required this.onGender,
    required this.onCountry,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ProfileHeading('About me'),
      ProfileTextField(profession, 'Profession', 100, enabled: enabled),
      ProfileTextField(pronouns, 'Pronouns', 40, enabled: enabled),
      ProfileChoice(
        label: 'Gender',
        value: gender,
        values: const {
          '': 'Prefer not to say',
          'woman': 'Woman',
          'man': 'Man',
          'nonbinary': 'Non-binary',
        },
        enabled: enabled,
        onChanged: onGender,
      ),
      Card(
        child: ListTile(
          enabled: enabled,
          leading: const Icon(Icons.public_rounded),
          title: const Text('Country'),
          subtitle: Text(countryNames[country] ?? 'Not added'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            final result = await pickProfileLabel(
              context,
              'Choose your country',
              countryNames,
              allowClear: true,
            );
            if (result != null && context.mounted) {
              onCountry(result.isEmpty ? null : result);
            }
          },
        ),
      ),
    ],
  );
}
