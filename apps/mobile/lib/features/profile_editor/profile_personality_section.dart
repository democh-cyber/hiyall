import 'package:flutter/material.dart';

import '../../core/personality.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';
import 'profile_form_widgets.dart';

/// Why Save waits while one or two tags are chosen, or null when the choice is valid (none, or three to five).
String? personalityWaiting(int count) =>
    count == 0 || count >= minPersonalityTags
    ? null
    : 'Choose $minPersonalityTags to $maxPersonalityTags personality tags, or none.';

/// The 19 personality tags as selectable chips with icons: none, or three to five. A sixth is not accepted and
/// the section says so.
class ProfilePersonalitySection extends StatelessWidget {
  final List<String> selected;
  final bool enabled;
  final void Function(String id, bool on) onToggle;
  const ProfilePersonalitySection({
    super.key,
    required this.selected,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final waiting = personalityWaiting(selected.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProfileHeading('Personality'),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final tag in personalityTags)
              _TagChoice(
                tag: tag,
                on: selected.contains(tag.id),
                // At the limit only the chosen ones stay active, so a sixth cannot be added.
                enabled:
                    enabled &&
                    (selected.contains(tag.id) ||
                        selected.length < maxPersonalityTags),
                onTap: () => onToggle(tag.id, !selected.contains(tag.id)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          waiting ??
              (selected.length >= maxPersonalityTags
                  ? '${selected.length} of $maxPersonalityTags chosen. Remove one to pick another.'
                  : '${selected.length} of $maxPersonalityTags chosen. Pick $minPersonalityTags to $maxPersonalityTags, or none.'),
          key: const Key('personality-hint'),
          style: TextStyle(
            fontSize: 12.5,
            color: waiting == null ? t.textSecondary : t.error,
          ),
        ),
      ],
    );
  }
}

class _TagChoice extends StatelessWidget {
  final PersonalityTag tag;
  final bool on, enabled;
  final VoidCallback onTap;
  const _TagChoice({
    required this.tag,
    required this.on,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return PressScale(
      key: Key('tag-${tag.id}'),
      onTap: enabled ? onTap : null,
      minHeight: 48,
      selected: on,
      semanticLabel: tag.label,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: enabled || on ? 1 : .45,
          child: Container(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 13,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: on ? t.accent.withValues(alpha: .16) : t.elevated,
              borderRadius: BorderRadius.circular(100),
              border: Border.all(
                color: on ? t.accent : t.hairline,
                width: on ? 1.6 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  on ? Icons.check_rounded : tag.icon,
                  size: 16,
                  color: t.accent,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    tag.label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: t.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
