import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/profile_labels.dart';
import 'profile_form_widgets.dart';
import 'profile_label_picker.dart';

/// The languages the person speaks, with a level each, and a way to add more.
class ProfileLanguagesSection extends StatelessWidget {
  final List<ProfileLanguage> languages;
  final bool enabled;
  final ValueChanged<String> onAdd;
  final ValueChanged<int> onRemove;
  final void Function(int index, String level) onLevel;
  const ProfileLanguagesSection({
    super.key,
    required this.languages,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
    required this.onLevel,
  });

  Future<void> _add(BuildContext context) async {
    final available = Map<String, String>.fromEntries(
      languageNames.entries.where(
        (e) =>
            e.key.length == 2 &&
            !languages.any((l) => l.code.toLowerCase() == e.key),
      ),
    );
    final result = await pickProfileLabel(context, 'Add a language', available);
    if (result != null && context.mounted) onAdd(result);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const ProfileHeading('Languages'),
      for (var i = 0; i < languages.length; i++)
        _LanguageRow(
          language: languages[i],
          enabled: enabled,
          onRemove: () => onRemove(i),
          onLevel: (level) => onLevel(i, level),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          onPressed: !enabled || languages.length >= 9
              ? null
              : () => _add(context),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add language'),
        ),
      ),
    ],
  );
}

class _LanguageRow extends StatelessWidget {
  final ProfileLanguage language;
  final bool enabled;
  final VoidCallback onRemove;
  final ValueChanged<String> onLevel;
  const _LanguageRow({
    required this.language,
    required this.enabled,
    required this.onRemove,
    required this.onLevel,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                languageLabel(language.code),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Remove ${languageLabel(language.code)}',
              onPressed: enabled ? onRemove : null,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('level-${language.code}-${language.level}'),
          initialValue: language.level,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Proficiency'),
          items: languageLevels.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: enabled
              ? (value) {
                  if (value != null) onLevel(value);
                }
              : null,
        ),
      ],
    ),
  );
}
