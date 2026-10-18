import 'package:flutter/material.dart';

import '../../shared/chat_tokens.dart';

/// Who may see a profile field. The server stores one of these per field (`fieldAudiences`).
const fieldAudienceLabels = <String, String>{
  'everyone': 'Everyone',
  'followers': 'Followers',
  'friends': 'Friends',
  'nobody': 'Only me',
};

const _audienceHints = <String, String>{
  'everyone': 'Anyone who can open your profile',
  'followers': 'People who follow you',
  'friends': 'Your confirmed friends',
  'nobody': 'Nobody else',
};

/// The audiences a member may pick. A member under 18 can only keep a field to themselves or share it with
/// friends; the server refuses anything more open for the fields it locks.
List<String> audienceOptions({required bool minor}) => minor
    ? const ['nobody', 'friends']
    : const ['everyone', 'followers', 'friends', 'nobody'];

/// The audience a field has when the server did not say (the defaults of docs/architecture/18-teen-safety.md).
String defaultFieldAudience(String field, {required bool minor}) =>
    switch (field) {
      'personality' => 'everyone',
      'birthday' => minor ? 'nobody' : 'friends',
      _ => minor ? 'nobody' : 'followers',
    };

/// Asks who may see [subject], with a radio choice among [options]. Null when dismissed.
Future<String?> showAudienceSheet(
  BuildContext context, {
  required String subject,
  required String current,
  required List<String> options,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (sheet) {
    final t = ChatTokens.of(sheet);
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('audience-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Who can see $subject?',
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: current,
              onChanged: (value) => Navigator.pop(sheet, value),
              child: Column(
                children: [
                  for (final option in options)
                    RadioListTile<String>(
                      key: Key('audience-$option'),
                      contentPadding: EdgeInsets.zero,
                      value: option,
                      title: Text(fieldAudienceLabels[option] ?? option),
                      subtitle: Text(
                        _audienceHints[option] ?? '',
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

/// "Who can see this" for one field: the current audience on a button that opens the picker. Reads as one
/// control to a screen reader ("About me, visible to Friends. Change.").
class AudienceRow extends StatelessWidget {
  /// What the audience is for, in a sentence: "your hometown".
  final String subject;
  final String value;
  final List<String> options;
  final bool enabled;
  final ValueChanged<String> onChanged;
  const AudienceRow({
    super.key,
    required this.subject,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final label = fieldAudienceLabels[value] ?? value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          Text(
            'Who can see this',
            style: TextStyle(fontSize: 13.5, color: t.textSecondary),
          ),
          Semantics(
            button: true,
            enabled: enabled,
            label: 'Who can see $subject: $label. Change.',
            excludeSemantics: true,
            child: OutlinedButton.icon(
              onPressed: !enabled
                  ? null
                  : () async {
                      final picked = await showAudienceSheet(
                        context,
                        subject: subject,
                        current: value,
                        options: options,
                      );
                      if (picked != null && picked != value) onChanged(picked);
                    },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 48),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              icon: const Icon(Icons.expand_more_rounded, size: 18),
              iconAlignment: IconAlignment.end,
              label: Text(label),
            ),
          ),
        ],
      ),
    );
  }
}
