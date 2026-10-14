import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';

/// The primary buttons under the identity: join (before joining) or the
/// Joined/Hosting + Members pair and an RSVP switch for events (after).
class SpaceActionBar extends StatelessWidget {
  final SocialSpace space;
  final bool busy, loading;
  final VoidCallback onJoin, onMembers;
  final ValueChanged<String> onRsvp;
  const SpaceActionBar({
    super.key,
    required this.space,
    required this.busy,
    required this.loading,
    required this.onJoin,
    required this.onMembers,
    required this.onRsvp,
  });

  @override
  Widget build(BuildContext context) {
    final x = space;
    if (!x.joined) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const Key('join-space'),
          onPressed:
              busy || loading || x.myState == 'pending' || x.status != 'open'
              ? null
              : onJoin,
          icon: Icon(
            x.myState == 'pending'
                ? Icons.hourglass_top_rounded
                : x.kind == 'event'
                ? Icons.event_available_rounded
                : Icons.add_rounded,
          ),
          label: Text(
            x.status != 'open'
                ? 'Not accepting new people'
                : x.myState == 'pending'
                ? 'Waiting for approval'
                : x.myState == 'invited'
                ? 'Accept invitation'
                : x.visibility == 'private'
                ? 'Request to join'
                : x.kind == 'event'
                ? 'RSVP · Going'
                : x.kind == 'moment'
                ? 'Join this Moment'
                : 'Join community',
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => showMessage(
                  context,
                  x.myRole == 'owner'
                      ? 'You host this ${spaceKindNames[x.kind]!.toLowerCase()}.'
                      : 'You’re a member. Leave from the ⋯ menu.',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: VibeColors.mint,
                  foregroundColor: VibeColors.ink,
                ),
                icon: const Icon(Icons.check_rounded),
                label: Text(x.myRole == 'owner' ? 'Hosting' : 'Joined'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onMembers,
                icon: const Icon(Icons.people_outline_rounded),
                label: const Text('Members'),
              ),
            ),
          ],
        ),
        if (x.kind == 'event') ...[
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'going',
                icon: Icon(Icons.check_rounded),
                label: Text('Going'),
              ),
              ButtonSegment(
                value: 'interested',
                icon: Icon(Icons.star_outline_rounded),
                label: Text('Interested'),
              ),
            ],
            selected: {x.myRsvp.isEmpty ? 'going' : x.myRsvp},
            showSelectedIcon: false,
            onSelectionChanged: busy ? null : (v) => onRsvp(v.first),
          ),
        ],
      ],
    );
  }
}
