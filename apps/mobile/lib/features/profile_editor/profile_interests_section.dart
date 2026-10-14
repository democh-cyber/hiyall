import 'package:flutter/material.dart';

import 'profile_form_widgets.dart';

const _suggestedInterests = [
  'Music',
  'Technology',
  'Travel',
  'Photography',
  'Finance',
  'Movies',
  'Art',
  'Gaming',
  'Reading',
  'Fitness',
  'Food',
  'Nature',
];

/// The interests chosen so far, suggestions to add, and a field for your own.
class ProfileInterestsSection extends StatelessWidget {
  final List<String> interests;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onAdd;
  final ValueChanged<String> onRemove;
  const ProfileInterestsSection({
    super.key,
    required this.interests,
    required this.controller,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ProfileHeading('My interests'),
      if (interests.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in interests)
              InputChip(
                label: Text(item),
                onDeleted: enabled ? () => onRemove(item) : null,
              ),
          ],
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in _suggestedInterests)
            if (!interests.any((v) => v.toLowerCase() == item.toLowerCase()))
              ActionChip(
                label: Text(item),
                onPressed: enabled ? () => onAdd(item) : null,
              ),
        ],
      ),
      const SizedBox(height: 14),
      TextFormField(
        controller: controller,
        enabled: enabled,
        maxLength: 40,
        decoration: InputDecoration(
          labelText: 'Add your own interest',
          suffixIcon: IconButton(
            tooltip: 'Add interest',
            onPressed: enabled ? () => onAdd(controller.text) : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ),
        onFieldSubmitted: enabled ? onAdd : null,
      ),
      Text(
        '${interests.length} of 10 · Your first interests lead the way.',
        style: const TextStyle(fontSize: 12),
      ),
    ],
  );
}
