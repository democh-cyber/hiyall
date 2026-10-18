import 'package:flutter/material.dart';

import '../../core/profile_limits.dart';
import 'audience_picker.dart';
import 'profile_form_widgets.dart';

/// "About me" and "From" (hometown or city), each with who can see it. Both are optional.
///
/// A hometown is a town or a city, never an address (the check is [looksLikeAddress]; the server refuses the
/// same). A member under 18 writes at most [maxMinorHometown] characters and only their friends can ever see it.
class ProfileTextSection extends StatelessWidget {
  final TextEditingController aboutMe, hometown;
  final bool minor, enabled;

  /// The audience now in effect for each field: the saved one, or what the person picked here.
  final String aboutMeAudience, hometownAudience;
  final void Function(String field, String audience) onAudience;
  const ProfileTextSection({
    super.key,
    required this.aboutMe,
    required this.hometown,
    required this.minor,
    required this.enabled,
    required this.aboutMeAudience,
    required this.hometownAudience,
    required this.onAudience,
  });

  @override
  Widget build(BuildContext context) {
    final options = audienceOptions(minor: minor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProfileHeading('About me'),
        ProfileTextField(
          aboutMe,
          'A line about you',
          maxAboutMe,
          enabled: enabled,
          lines: 2,
          validator: (v) =>
              (v ?? '').contains('\n') ? 'Keep it to one line.' : null,
        ),
        AudienceRow(
          key: const Key('audience-about-me'),
          subject: 'your about me',
          value: aboutMeAudience,
          options: options,
          enabled: enabled,
          onChanged: (v) => onAudience('aboutMe', v),
        ),
        const ProfileHeading('From'),
        ProfileTextField(
          hometown,
          'Hometown or city',
          minor ? maxMinorHometown : maxHometown,
          enabled: enabled,
          helper: minor
              ? 'A town or city is enough. Not your address. Only your friends can see this.'
              : 'A town or city is enough. Not your address.',
          validator: (v) => looksLikeAddress((v ?? '').trim())
              ? 'Write a town or city, not an address.'
              : null,
        ),
        AudienceRow(
          key: const Key('audience-hometown'),
          subject: 'your hometown',
          value: hometownAudience,
          options: options,
          enabled: enabled,
          onChanged: (v) => onAudience('hometown', v),
        ),
      ],
    );
  }
}
