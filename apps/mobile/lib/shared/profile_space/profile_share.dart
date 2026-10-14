import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';

Future<void> shareProfile(BuildContext context, Profile profile) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Share a little of your world',
              style: Theme.of(sheet).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text('@${profile.username}'),
            const SizedBox(height: 12),
            const Text(
              'Share your username so friends can find you on Hiyall.',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy username'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: '@${profile.username}'),
                );
                if (sheet.mounted) Navigator.pop(sheet);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Username copied.')),
                  );
                }
              },
            ),
            if (kIsWeb)
              OutlinedButton.icon(
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Copy profile link'),
                onPressed: () async {
                  final link = Uri.base
                      .replace(fragment: '/discover/person/${profile.userId}')
                      .toString();
                  await Clipboard.setData(ClipboardData(text: link));
                  if (sheet.mounted) Navigator.pop(sheet);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Profile link copied.')),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    ),
  );
}
