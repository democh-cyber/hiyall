import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/activity_state.dart';
import '../core/api.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';

/// Follow and friend controls for another account. Every action goes to the
/// server, then the profile is reloaded so visibility follows the new state.
class RelationshipBar extends ConsumerStatefulWidget {
  final Profile profile;
  final Widget? trailing;
  const RelationshipBar({super.key, required this.profile, this.trailing});
  @override
  ConsumerState<RelationshipBar> createState() => _RelationshipBarState();
}

class _RelationshipBarState extends ConsumerState<RelationshipBar> {
  bool busy = false;

  /// [done] is shown on success; an action may return its own message instead.
  Future<void> run(
    Future<Object?> Function(ApiClient api, Session s) action,
    String done,
  ) async {
    setState(() => busy = true);
    try {
      final session = ref.read(sessionProvider).asData!.value!;
      final result = await action(ref.read(apiProvider), session);
      if (result is String) done = result;
      ref.invalidate(otherProfileProvider(widget.profile.userId));
      ref.invalidate(profileProvider);
      // Answering a request also clears its notification on the server.
      ref.invalidate(activityProvider);
      if (mounted && done.isNotEmpty) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final r = p.relationship ?? const Relationship();
    final id = p.userId;
    final name = p.displayName;
    final buttons = <Widget>[];

    switch (r.friendship) {
      case 'accepted':
        buttons.add(
          OutlinedButton.icon(
            key: const Key('friends'),
            onPressed: busy
                ? null
                : () async {
                    if (await confirm(
                      'Remove $name as a friend?',
                      'You’ll stop seeing anything they share only with friends.',
                      'Remove',
                    )) {
                      await run((api, s) => api.unfriend(s, id), '');
                    }
                  },
            icon: const Icon(Icons.how_to_reg_rounded, size: 18),
            label: const Text('Friends'),
          ),
        );
      case 'pending_incoming':
        buttons
          ..add(
            FilledButton.icon(
              key: const Key('accept-friend'),
              onPressed: busy || r.friendRequestId == null
                  ? null
                  : () => run(
                      (api, s) =>
                          api.respondFriendRequest(s, r.friendRequestId!, true),
                      'You and $name are friends now.',
                    ),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Accept'),
            ),
          )
          ..add(
            OutlinedButton(
              key: const Key('decline-friend'),
              onPressed: busy || r.friendRequestId == null
                  ? null
                  : () => run(
                      (api, s) => api.respondFriendRequest(
                        s,
                        r.friendRequestId!,
                        false,
                      ),
                      '',
                    ),
              child: const Text('Decline'),
            ),
          );
      case 'pending_outgoing':
        buttons.add(
          OutlinedButton.icon(
            key: const Key('cancel-friend'),
            onPressed: busy || r.friendRequestId == null
                ? null
                : () => run(
                    (api, s) => api.cancelFriendRequest(s, r.friendRequestId!),
                    'Friend request withdrawn.',
                  ),
            icon: const Icon(Icons.schedule_rounded, size: 18),
            label: const Text('Requested'),
          ),
        );
      default:
        if (r.canFriendRequest) {
          buttons.add(
            FilledButton.icon(
              key: const Key('add-friend'),
              onPressed: busy
                  ? null
                  : () => run((api, s) async {
                      await api.sendFriendRequest(s, id);
                      return null;
                    }, 'Friend request sent.'),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: const Text('Add friend'),
            ),
          );
        }
    }

    // Friends already see "followers" content, so following is optional there.
    switch (r.following) {
      case 'active':
        buttons.add(
          OutlinedButton(
            key: const Key('following'),
            onPressed: busy
                ? null
                : () async {
                    if (await confirm(
                      'Unfollow $name?',
                      'You can follow again any time.',
                      'Unfollow',
                    )) {
                      await run((api, s) => api.unfollow(s, id), '');
                    }
                  },
            child: const Text('Following'),
          ),
        );
      case 'pending':
        buttons.add(
          OutlinedButton(
            key: const Key('follow-requested'),
            onPressed: busy
                ? null
                : () => run(
                    (api, s) => api.unfollow(s, id),
                    'Follow request withdrawn.',
                  ),
            child: const Text('Follow requested'),
          ),
        );
      default:
        if (r.canFollow) {
          buttons.add(
            OutlinedButton(
              key: const Key('follow'),
              onPressed: busy
                  ? null
                  : () => run(
                      (api, s) async => await api.follow(s, id) == 'pending'
                          ? 'Follow request sent.'
                          : null,
                      '',
                    ),
              child: Text(r.followedBy ? 'Follow back' : 'Follow'),
            ),
          );
        }
    }
    if (widget.trailing != null) buttons.add(widget.trailing!);
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

/// Shown instead of profile content when the owner's audience excludes the viewer.
class LockedProfile extends StatelessWidget {
  final Profile profile;
  final Widget actions;
  const LockedProfile({
    super.key,
    required this.profile,
    required this.actions,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = profile.displayName.trim().isEmpty
        ? '?'
        : profile.displayName.trim().characters.first.toUpperCase();
    return ReadingWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: VibeColors.lilac,
                borderRadius: BorderRadius.circular(32),
              ),
              child: Text(
                initial,
                style: const TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  color: VibeColors.ink,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            profile.displayName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(
            '@${profile.username}',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Center(child: actions),
          const SizedBox(height: 28),
          VibePanel(
            child: Column(
              children: [
                const Icon(Icons.lock_outline_rounded, size: 28),
                const SizedBox(height: 12),
                Text(
                  'This space is private',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Only people ${profile.displayName} has let in can see their profile. Follow or add them as a friend to ask.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
