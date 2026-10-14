import 'package:flutter/material.dart';

import '../../shared/segmented.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';

/// The Spaces list's title block: heading, kind tabs, the "Joined" filter and
/// the loading, error or empty state that sits above the cards.
class SpacesHeader extends StatelessWidget {
  final bool nested, mine, loading, hasItems, canCreate;
  final String kind;
  final Object? error;
  final ValueChanged<String> onKind;
  final ValueChanged<bool> onMine;
  final VoidCallback onRetry, onCreate;
  const SpacesHeader({
    super.key,
    required this.nested,
    required this.kind,
    required this.mine,
    required this.loading,
    required this.hasItems,
    required this.canCreate,
    required this.error,
    required this.onKind,
    required this.onMine,
    required this.onRetry,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plural = spaceKinds[kind]!.toLowerCase();
    final visible = visibleSpaceKinds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          nested
              ? 'Plans inside\nthis community.'
              : 'Small circles.\nReal conversations.',
          style: Theme.of(context).textTheme.headlineLarge
              ?.copyWith(fontSize: 34, height: 1.06, letterSpacing: -1.2),
        ),
        const SizedBox(height: 10),
        Text(
          nested
              ? 'Timed get-togethers hosted by this circle.'
              : 'Find communities around things you actually care about.',
          style: TextStyle(
            fontSize: 14,
            height: 1.55,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        if (visible.length > 1)
          VibeSegmented<String>(
            segments: [
              for (final k in visible.entries)
                if (!nested || k.key != 'community') (k.key, k.value),
            ],
            selected: kind,
            onChanged: onKind,
          ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: Text(
                '${mine ? 'Your' : 'All'} $plural',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            FilterChip(
              label: const Text('Joined'),
              selected: mine,
              onSelected: onMine,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (error != null)
          FailureCard(error: error!, retry: onRetry)
        else if (loading && !hasItems)
          const VibeLoading()
        else if (!hasItems)
          EmptyCard(
            icon: spaceKindStyle(kind).$1,
            title: mine ? 'Nothing joined yet' : 'A quiet corner for now',
            description: mine
                ? 'Spaces you join or host show up here.'
                : 'No $plural here yet. Start something worth joining.',
            action: canCreate
                ? FilledButton.icon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.add),
                    label: Text(
                      'Start a ${spaceKindNames[kind]!.toLowerCase()}',
                    ),
                  )
                : null,
          ),
      ],
    );
  }
}
