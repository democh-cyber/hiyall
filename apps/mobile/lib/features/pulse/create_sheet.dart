import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The "+" menu: a circle, a post or a story.
Future<void> showCreateSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Start a circle'),
                subtitle: const Text('Community, Moment or event'),
                onTap: () {
                  Navigator.pop(sheet);
                  context.push('/spaces');
                },
              ),
              ListTile(
                key: const Key('create-post'),
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('New post'),
                subtitle: const Text('Words, photos or both'),
                onTap: () {
                  Navigator.pop(sheet);
                  context.push('/compose');
                },
              ),
              ListTile(
                key: const Key('create-story'),
                leading: const Icon(Icons.auto_awesome_motion_outlined),
                title: const Text('Add to your story'),
                subtitle: const Text('Gone in 24 hours or less'),
                onTap: () {
                  Navigator.pop(sheet);
                  context.push('/story/new');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
