import 'package:flutter/material.dart';

import '../../core/support.dart';
import '../../shared/chat_tokens.dart';

/// How a support category is named and drawn.
class SupportCategoryStyle {
  final String label;
  final IconData icon;
  const SupportCategoryStyle(this.label, this.icon);

  static SupportCategoryStyle of(SupportCategory c) => switch (c) {
    SupportCategory.account => const SupportCategoryStyle(
      'Account',
      Icons.person_outline_rounded,
    ),
    SupportCategory.safety => const SupportCategoryStyle(
      'Safety',
      Icons.shield_outlined,
    ),
    SupportCategory.bug => const SupportCategoryStyle(
      'Bug',
      Icons.bug_report_outlined,
    ),
    SupportCategory.other => const SupportCategoryStyle(
      'Other',
      Icons.chat_bubble_outline_rounded,
    ),
  };
}

/// The plain-language warning shown above every box that sends text to support.
const supportEncryptionNote =
    'Messages to support are not end-to-end encrypted. Our team can read them. '
    'Don’t send passwords or ID numbers.';

/// Added to the note when the topic is Safety.
const supportEmergencyNote =
    'If you or someone else is in immediate danger, call your local emergency services first.';

/// The warning in a bordered card with an icon. At least 4.5:1 in both themes (text and surface come
/// from [ChatTokens]).
class SupportNote extends StatelessWidget {
  final String text;
  final IconData icon;
  const SupportNote(
    this.text, {
    super.key,
    this.icon = Icons.info_outline_rounded,
  });
  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.bg2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tokens.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: tokens.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(height: 1.45, color: tokens.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Open" or "Closed", as a small pill.
class SupportStatusPill extends StatelessWidget {
  final bool open;
  const SupportStatusPill({super.key, required this.open});
  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: tokens.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          open ? 'Open' : 'Closed',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: tokens.textSecondary,
          ),
        ),
      ),
    );
  }
}
