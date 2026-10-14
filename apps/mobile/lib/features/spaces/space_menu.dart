import 'package:flutter/material.dart';

import '../../core/api.dart';
import 'space_format.dart';

/// The ⋯ menu entries for a space. Values: `refresh`, `rules`, `edit`,
/// `status:<open|closed|archived>`, `report`, `leave`.
List<PopupMenuEntry<String>> spaceMenuEntries(SocialSpace x, String? me) {
  PopupMenuItem<String> item(String value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Flexible(child: Text(label)),
          ],
        ),
      );
  return [
    item('refresh', Icons.refresh, 'Refresh'),
    if (x.rules.isNotEmpty)
      item(
        'rules',
        Icons.info_outline_rounded,
        '${spaceKindNames[x.kind]} rules',
      ),
    if (x.host) ...[
      const PopupMenuDivider(),
      item('edit', Icons.edit_outlined, 'Edit details & schedule'),
      for (final status in ['open', 'closed', 'archived'])
        if (status != x.status)
          item(
            'status:$status',
            status == 'open'
                ? Icons.lock_open_rounded
                : status == 'closed'
                ? Icons.lock_outline_rounded
                : Icons.archive_outlined,
            status == 'open'
                ? 'Reopen'
                : status == 'closed'
                ? 'Close to new people'
                : 'Archive',
          ),
    ],
    if (x.owner.userId != me || (x.joined && x.myRole != 'owner'))
      const PopupMenuDivider(),
    if (x.owner.userId != me)
      item(
        'report',
        Icons.flag_outlined,
        'Report ${spaceKindNames[x.kind]!.toLowerCase()}',
      ),
    if (x.joined && x.myRole != 'owner')
      item('leave', Icons.logout_rounded, 'Leave'),
  ];
}

void showSpaceRules(BuildContext context, SocialSpace x) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${spaceKindNames[x.kind]} rules',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(x.rules, style: const TextStyle(fontSize: 15, height: 1.55)),
            ],
          ),
        ),
      ),
    );

/// Asks before leaving; true when the person confirmed.
Future<bool?> confirmLeaveSpace(BuildContext context, SocialSpace x) {
  final name = spaceKindNames[x.kind]!.toLowerCase();
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Leave this $name?'),
      content: Text(
        x.kind == 'community'
            ? 'You’ll lose access to its discussion and upcoming events.'
            : 'You’ll lose access to its discussion.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Leave'),
        ),
      ],
    ),
  );
}
