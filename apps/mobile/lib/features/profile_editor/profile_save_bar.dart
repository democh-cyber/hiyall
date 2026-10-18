import 'package:flutter/material.dart';

/// The error, the reload button after a conflict, and the Save button.
class ProfileSaveBar extends StatelessWidget {
  final String? error;
  final bool conflict, busy, canSave;

  /// Why Save waits, when the form is not ready (shown above the button).
  final String? waiting;
  final VoidCallback onReload;
  final VoidCallback onSave;
  const ProfileSaveBar({
    super.key,
    required this.error,
    required this.conflict,
    required this.busy,
    required this.canSave,
    this.waiting,
    required this.onReload,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 16),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (conflict)
        TextButton(
          onPressed: onReload,
          child: const Text('Reload latest profile'),
        ),
      if (waiting != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            waiting!,
            key: const Key('save-waiting'),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      FilledButton(
        onPressed: canSave ? onSave : null,
        child: Text(busy ? 'Saving…' : 'Save profile'),
      ),
      const SizedBox(height: 16),
    ],
  );
}
