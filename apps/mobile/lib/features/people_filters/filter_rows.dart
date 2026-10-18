import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// A row with a switch, for a setting that is simply on or off.
///
/// With [enabled] false the row is dimmed, the switch is off and nothing can be toggled; [value] then says why.
class SwitchRow extends StatelessWidget {
  final String label, value;
  final bool on;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  const SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.on,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(14);
    return Semantics(
      toggled: on,
      enabled: enabled,
      label: label,
      hint: value,
      excludeSemantics: true,
      onTap: enabled ? () => onChanged(!on) : null,
      child: Material(
        color: on ? scheme.primary.withValues(alpha: .06) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: on
                ? scheme.primary.withValues(alpha: .55)
                : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? () => onChanged(!on) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: !enabled
                                ? scheme.onSurfaceVariant
                                : on
                                ? scheme.primary
                                : scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          value,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Switch(value: on, onChanged: enabled ? onChanged : null),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FilterRow extends StatelessWidget {
  final String label;
  final String? value;
  final bool selected, radio, opensPicker, checkbox;
  final VoidCallback onTap;
  const FilterRow({
    super.key,
    required this.label,
    this.value,
    required this.selected,
    this.radio = false,
    this.opensPicker = false,
    this.checkbox = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurface;
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: .06)
            : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected
                ? scheme.primary.withValues(alpha: .55)
                : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  if (radio) ...[
                    Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: selected ? foreground : scheme.outlineVariant,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: foreground,
                          ),
                        ),
                        if (value != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            value!,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (checkbox) ...[
                    const SizedBox(width: 12),
                    Icon(
                      selected
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 24,
                      color: selected ? foreground : scheme.outlineVariant,
                    ),
                  ],
                  if (opensPicker) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 22,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// An icon before the label (a personality tag).
  final IconData? icon;
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onPrimary
        : onTap == null
        ? scheme.onSurfaceVariant.withValues(alpha: .5)
        : scheme.onSurface;
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      child: AnimatedContainer(
        duration: VibeMotion.duration(context),
        decoration: ShapeDecoration(
          color: selected ? scheme.primary : scheme.surface,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      ExcludeSemantics(
                        child: Icon(icon, size: 16, color: foreground),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
