import 'package:flutter/material.dart';

import '../core/api.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';

/// What the row menu of a Discover person can ask for. The screen runs it with
/// the same handlers as the profile and conversation menus (`confirmBlock`,
/// `blockAccount`, `showReportSheet` in `safety.dart`).
enum PersonMenuChoice { profile, report, block }

/// The compact sheet behind a long press (or the "More options" action for
/// TalkBack and VoiceOver) on a Discover row: View profile, Report, Block.
/// Returns what was chosen, or null when dismissed.
Future<PersonMenuChoice?> showPersonMenu(
  BuildContext context,
  Profile person,
) => showModalBottomSheet<PersonMenuChoice>(
  context: context,
  useRootNavigator: true,
  showDragHandle: true,
  builder: (context) {
    final t = ChatTokens.of(context);
    final error = Theme.of(context).colorScheme.error;
    final name = person.displayName;
    return SafeArea(
      child: Column(
        key: const Key('person-menu'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
            child: Row(
              children: [
                PersonAvatar(
                  name: name,
                  avatarUrl: person.avatarUrl,
                  userId: person.userId,
                  radius: 18,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.3,
                        color: t.text,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            key: const Key('person-menu-profile'),
            leading: const Icon(Icons.person_outline_rounded),
            title: const Text('View profile'),
            onTap: () => Navigator.pop(context, PersonMenuChoice.profile),
          ),
          ListTile(
            key: const Key('person-menu-report'),
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report'),
            onTap: () => Navigator.pop(context, PersonMenuChoice.report),
          ),
          ListTile(
            key: const Key('person-menu-block'),
            leading: Icon(Icons.block_rounded, color: error),
            title: Text('Block', style: TextStyle(color: error)),
            onTap: () => Navigator.pop(context, PersonMenuChoice.block),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  },
);
