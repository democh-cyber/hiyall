import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/app_info.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../core/user_error.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';
import 'spaces_actions.dart';

/// Joins, requests or accepts an invitation, then reports the outcome.
Future<SocialSpace?> joinSpace(
  BuildContext context,
  WidgetRef ref,
  SocialSpace s, {
  String rsvp = 'going',
}) async {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return null;
  try {
    final next = await ref
        .read(spaceActionsProvider)
        .membership(session, s.spaceId, rsvp: rsvp);
    if (context.mounted) {
      showMessage(
        context,
        next.myState == 'pending'
            ? 'Request sent. The host will review it.'
            : 'You’re in ${s.title}.',
      );
    }
    return next;
  } catch (e) {
    if (context.mounted) showFailure(context, e);
    return null;
  }
}

/// The join call to action for a space card or row, animated between states.
class SpaceJoinButton extends StatelessWidget {
  final SocialSpace space;
  final VoidCallback? onJoin, onOpen;
  final bool busy;
  const SpaceJoinButton(
    this.space, {
    super.key,
    required this.onJoin,
    required this.onOpen,
    this.busy = false,
  });
  @override
  Widget build(BuildContext context) {
    final s = space;
    final Widget button;
    if (s.joined) {
      button = OutlinedButton.icon(
        key: const ValueKey('joined'),
        onPressed: onOpen,
        icon: const Icon(Icons.check_rounded, size: 18),
        label: Text(
          s.myRole == 'owner'
              ? 'Hosting'
              : s.kind == 'event'
              ? (s.myRsvp == 'interested' ? 'Interested' : 'Going')
              : 'Joined',
        ),
      );
    } else if (s.myState == 'pending') {
      button = const OutlinedButton(
        key: ValueKey('pending'),
        onPressed: null,
        child: Text('Requested'),
      );
    } else if (s.status != 'open' ||
        spaceTiming(s) == 'Ended' ||
        (!FeatureFlags.events && s.kind != 'community')) {
      // Events and Moments are read-only while they are switched off.
      button = const SizedBox.shrink(key: ValueKey('closed'));
    } else {
      final label = s.myState == 'invited'
          ? 'Accept invite'
          : s.visibility == 'private'
          ? 'Request to join'
          : switch (s.kind) {
              'event' => 'I’m interested',
              'moment' => 'Join Moment',
              _ => 'Join community',
            };
      button = FilledButton(
        key: const ValueKey('join'),
        onPressed: busy ? null : onJoin,
        child: Text(busy ? 'Joining…' : label),
      );
    }
    return AnimatedSwitcher(
      duration: VibeMotion.duration(context),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: .92, end: 1.0).animate(a),
          child: child,
        ),
      ),
      child: button,
    );
  }
}
