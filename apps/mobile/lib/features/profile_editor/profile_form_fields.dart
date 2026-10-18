import 'package:flutter/material.dart';

import '../../core/api.dart';

/// What the profile form edits: its text controllers and choices, started from a [Profile].
/// Holds no widget state; the form decides when to rebuild.
class ProfileFormFields {
  final TextEditingController name,
      username,
      headline,
      quote,
      bio,
      profession,
      pronouns,
      vibe,
      aboutMe,
      hometown;
  final interest = TextEditingController();
  String gender;
  String? country;
  final List<ProfileLanguage> languages;
  final List<String> interests;

  /// Ids of the chosen personality tags (none, or three to five).
  final List<String> personalityTags;

  /// Audiences the person changed in this form, by field (`aboutMe`, `hometown`, `personality`). Only
  /// these are sent to the privacy settings; a field left alone keeps its saved audience.
  final Map<String, String> audienceChanges = {};
  String accent, pattern, frame;

  ProfileFormFields(Profile p)
    : name = TextEditingController(text: p.displayName),
      username = TextEditingController(text: p.username),
      headline = TextEditingController(text: p.headline),
      quote = TextEditingController(text: p.quote),
      bio = TextEditingController(text: p.bio),
      profession = TextEditingController(text: p.profession),
      pronouns = TextEditingController(text: p.pronouns),
      vibe = TextEditingController(text: p.currentVibe),
      aboutMe = TextEditingController(text: p.aboutMe),
      hometown = TextEditingController(text: p.hometown),
      gender = const ['woman', 'man', 'nonbinary'].contains(p.gender)
          ? p.gender
          : '',
      country = p.country,
      languages = [...p.languages],
      interests = [...p.interests],
      personalityTags = [...p.personalityTags],
      accent = ['lime', 'violet', 'cyan'].contains(p.profileAccent)
          ? p.profileAccent
          : 'lime',
      pattern = ['glow', 'orbit', 'plain'].contains(p.profilePattern)
          ? p.profilePattern
          : 'glow',
      frame = ['minimal', 'orbit'].contains(p.avatarFrame)
          ? p.avatarFrame
          : 'minimal';

  /// The fields as the server's profile update expects them.
  Map<String, dynamic> patch() => {
    'displayName': name.text.trim(),
    'username': username.text.trim(),
    'headline': headline.text.trim(),
    'bio': bio.text.trim(),
    'quote': quote.text.trim(),
    'profession': profession.text.trim(),
    'pronouns': pronouns.text.trim(),
    'gender': gender,
    'country': country,
    'languages': languages.map((v) => v.toJson()).toList(),
    'interests': interests,
    'personalityTags': personalityTags,
    'aboutMe': aboutMe.text.trim(),
    'hometown': hometown.text.trim(),
    'currentVibe': vibe.text.trim(),
    'profileAccent': accent,
    'profilePattern': pattern,
    'avatarFrame': frame,
  };

  void dispose() {
    for (final controller in [
      name,
      username,
      headline,
      bio,
      quote,
      profession,
      pronouns,
      vibe,
      aboutMe,
      hometown,
      interest,
    ]) {
      controller.dispose();
    }
  }
}
