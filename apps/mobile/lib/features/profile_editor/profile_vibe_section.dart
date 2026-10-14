import 'package:flutter/material.dart';

import 'profile_form_widgets.dart';

const _suggestedVibes = [
  '🎧 Listening to music',
  '☕ Coffee + work',
  '📚 Reading',
  '✈️ Travel mode',
  '🎮 Gaming',
  '🌿 Taking it slow',
];

/// The current vibe: a field, quick picks and a way to turn it off.
class ProfileVibeSection extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onPick;
  final VoidCallback onClear;
  const ProfileVibeSection({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ProfileHeading('Current Vibe'),
      ProfileTextField(controller, 'What’s your vibe?', 80, enabled: enabled),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in _suggestedVibes)
            ActionChip(
              label: Text(item),
              onPressed: enabled ? () => onPick(item) : null,
            ),
        ],
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: enabled ? onClear : null,
          child: const Text('Turn my vibe off'),
        ),
      ),
    ],
  );
}

/// Profile accent, background and avatar frame.
class ProfileSignatureSection extends StatelessWidget {
  final String accent, pattern, frame;
  final bool enabled;
  final ValueChanged<String> onAccent, onPattern, onFrame;
  const ProfileSignatureSection({
    super.key,
    required this.accent,
    required this.pattern,
    required this.frame,
    required this.enabled,
    required this.onAccent,
    required this.onPattern,
    required this.onFrame,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ProfileHeading('Your signature'),
      ProfileChoice(
        label: 'Profile accent',
        value: accent,
        values: const {
          'lime': 'Electric lime',
          'violet': 'Soft violet',
          'cyan': 'Quiet cyan',
        },
        enabled: enabled,
        onChanged: onAccent,
      ),
      ProfileChoice(
        label: 'Profile background',
        value: pattern,
        values: const {
          'glow': 'Ambient glow',
          'orbit': 'Soft orbit',
          'plain': 'Minimal',
        },
        enabled: enabled,
        onChanged: onPattern,
      ),
      ProfileChoice(
        label: 'Avatar frame',
        value: frame,
        values: const {'minimal': 'Clean border', 'orbit': 'Accent outline'},
        enabled: enabled,
        onChanged: onFrame,
      ),
    ],
  );
}
