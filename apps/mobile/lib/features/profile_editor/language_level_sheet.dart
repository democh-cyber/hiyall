import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/profile_labels.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/language_chip.dart';

/// Asks how well the person speaks [code]: the six levels with a line each, as radio choices, the current one
/// selected. Null when dismissed.
Future<int?> pickLanguageLevel(
  BuildContext context, {
  required String code,
  required int current,
}) => showModalBottomSheet<int>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (sheet) {
    final t = ChatTokens.of(sheet);
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('level-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                'How well do you speak ${languageLabel(code)}?',
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            RadioGroup<int>(
              groupValue: current,
              onChanged: (value) => Navigator.pop(sheet, value),
              child: Column(
                children: [
                  for (
                    var level = minLanguageLevel;
                    level <= maxLanguageLevel;
                    level++
                  )
                    RadioListTile<int>(
                      key: Key('level-$level'),
                      contentPadding: EdgeInsets.zero,
                      value: level,
                      secondary: LevelMeter(level: level),
                      title: Text(languageLevelNames[level]),
                      subtitle: Text(
                        languageLevelHints[level],
                        style: TextStyle(color: t.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  },
);
