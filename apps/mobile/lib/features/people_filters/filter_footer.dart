import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// The sticky bottom bar of the filter sheet: reset and apply.
class FilterFooter extends StatelessWidget {
  final bool hasFilters;
  final VoidCallback onClear, onApply;
  const FilterFooter({
    super.key,
    required this.hasFilters,
    required this.onClear,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              TextButton(
                key: const Key('clear-active-filters'),
                onPressed: hasFilters ? onClear : null,
                child: const Text('Reset all'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: onApply,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder(),
                    disabledBackgroundColor: VibeColors.lime.withValues(
                      alpha: .35,
                    ),
                    disabledForegroundColor: scheme.onSurface.withValues(
                      alpha: .65,
                    ),
                  ),
                  child: const Text('Show people', textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
