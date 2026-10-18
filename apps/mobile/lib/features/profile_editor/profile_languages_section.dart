import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/profile_labels.dart';
import '../../core/profile_limits.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/language_chip.dart';
import '../../shared/press_scale.dart';
import 'language_level_sheet.dart';
import 'profile_form_widgets.dart';
import 'profile_label_picker.dart';

/// The languages the person speaks (up to [maxProfileLanguages]), each with a level they pick from six, and a
/// way to add more. The level is chosen in the same flow as the language, starting at "Conversational".
class ProfileLanguagesSection extends StatelessWidget {
  final List<ProfileLanguage> languages;
  final bool enabled;
  final void Function(ProfileLanguage language) onAdd;
  final ValueChanged<int> onRemove;
  final void Function(int index, int level) onLevel;
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
    final code = await pickProfileLabel(context, 'Add a language', available);
    if (code == null || !context.mounted) return;
    final level = await pickLanguageLevel(
      context,
      code: code,
      current: defaultLanguageLevel,
    );
    if (level != null) onAdd(ProfileLanguage(code, level));
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final full = languages.length >= maxProfileLanguages;
    return Column(
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
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 14,
          children: [
            OutlinedButton.icon(
              key: const Key('add-language'),
              onPressed: !enabled || full ? null : () => _add(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add language'),
            ),
            Text(
              '${languages.length} of $maxProfileLanguages',
              key: const Key('languages-count'),
              style: TextStyle(fontSize: 12.5, color: t.textSecondary),
            ),
          ],
        ),
      ],
    );
  }
}

class _LanguageRow extends StatelessWidget {
  final ProfileLanguage language;
  final bool enabled;
  final VoidCallback onRemove;
  final ValueChanged<int> onLevel;
  const _LanguageRow({
    required this.language,
    required this.enabled,
    required this.onRemove,
    required this.onLevel,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final name = languageLabel(language.code);
    return Padding(
      key: ValueKey('language-row-${language.code}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: PressScale(
              key: Key('level-${language.code}'),
              onTap: enabled
                  ? () async {
                      final level = await pickLanguageLevel(
                        context,
                        code: language.code,
                        current: language.level,
                      );
                      if (level != null && level != language.level) {
                        onLevel(level);
                      }
                    }
                  : null,
              borderRadius: BorderRadius.circular(16),
              minHeight: 56,
              semanticLabel: '${languageSemantics(language)}. Change level.',
              child: ExcludeSemantics(
                child: Container(
                  padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: t.elevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: t.hairline),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: t.text,
                              ),
                            ),
                            Text(
                              languageLevelName(language.level),
                              style: TextStyle(
                                fontSize: 13,
                                color: t.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      LevelMeter(level: language.level, height: 14),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.expand_more_rounded,
                        size: 20,
                        color: t.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Remove $name',
            onPressed: enabled ? onRemove : null,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
