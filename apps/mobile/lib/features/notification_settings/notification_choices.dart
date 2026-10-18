import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notification_prefs.dart';
import '../../core/user_error.dart';
import '../../shared/widgets.dart';

/// A titled panel in the Notifications group of Settings.
class NotificationSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const NotificationSection(this.title, this.children, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        VibePanel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      ],
    ),
  );
}

/// One server-side choice as a switch. It shows the new value at once, and the controller puts it back
/// (and this shows the server's words) if the change is refused.
class PrefSwitch extends ConsumerWidget {
  final NotificationPref pref;
  final IconData icon;
  final String title;
  final String subtitle;

  /// False while the master switch is off.
  final bool active;
  final bool value;
  const PrefSwitch({
    super.key,
    required this.pref,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    this.active = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) => SwitchListTile(
    key: Key('notifications-${pref.field}'),
    secondary: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    value: value,
    onChanged: active ? (on) => _change(context, ref, on) : null,
  );

  Future<void> _change(BuildContext context, WidgetRef ref, bool on) async {
    // Held past the await: the screen may be gone when the answer arrives.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(notificationPrefsControllerProvider.notifier)
          .set(pref, on);
    } catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(friendlyError(error))));
    }
  }
}

/// The server-side choices: master switch, messages, the social group and names. Nothing is sent
/// until a switch is touched, and each switch sends only its own field.
class NotificationChoices extends ConsumerWidget {
  const NotificationChoices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsState = ref.watch(notificationPrefsControllerProvider);
    final prefs = prefsState.asData?.value;
    if (prefs == null) {
      return NotificationSection('Choices', [
        if (prefsState.isLoading)
          const ListTile(
            key: Key('notifications-loading'),
            leading: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            title: Text('Loading your choices…'),
          )
        else
          ListTile(
            key: const Key('notifications-error'),
            leading: const Icon(Icons.cloud_off_rounded),
            title: Text(
              'Couldn’t load your choices',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(friendlyError(prefsState.error)),
            trailing: TextButton(
              key: const Key('notifications-retry'),
              onPressed: () => ref
                  .read(notificationPrefsControllerProvider.notifier)
                  .reload(),
              child: const Text('Retry'),
            ),
          ),
      ]);
    }
    final on = prefs.enabled;
    Widget tile(
      NotificationPref pref,
      IconData icon,
      String title,
      String subtitle,
    ) => PrefSwitch(
      pref: pref,
      icon: icon,
      title: title,
      subtitle: subtitle,
      value: prefs[pref],
      active: pref == NotificationPref.enabled || on,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotificationSection('What to tell me', [
          tile(
            NotificationPref.enabled,
            Icons.notifications_active_outlined,
            'Push notifications',
            on ? 'Turn this off to silence everything below.' : 'Off. Nothing below is sent. Security alerts, like a new device on your account, still arrive.',
          ),
          tile(
            NotificationPref.chat,
            Icons.chat_bubble_outline_rounded,
            'Messages',
            'When someone writes to you',
          ),
        ]),
        NotificationSection('Social', [
          tile(
            NotificationPref.follows,
            Icons.person_add_alt_outlined,
            'New followers',
            'Followers, follow requests and accepted requests',
          ),
          tile(
            NotificationPref.friendRequests,
            Icons.group_add_outlined,
            'Friend requests and invites',
            'Friend requests, accepted requests and space invitations',
          ),
          tile(
            NotificationPref.comments,
            Icons.mode_comment_outlined,
            'Comments',
            'When someone comments on your post',
          ),
          tile(
            NotificationPref.replies,
            Icons.reply_rounded,
            'Replies',
            'When someone replies to your comment',
          ),
          tile(
            NotificationPref.reactions,
            Icons.favorite_border_rounded,
            'Reactions',
            'When someone reacts to your post',
          ),
          tile(
            NotificationPref.visits,
            Icons.visibility_outlined,
            'Profile visits',
            'Get told when someone opens your profile for the first time. Only people who could see you anyway.',
          ),
        ]),
        NotificationSection('On your lock screen', [
          tile(
            NotificationPref.hideNames,
            Icons.visibility_off_outlined,
            'Hide names in notifications',
            'Social notifications say “You have a new follower” instead of naming the person. On by default if you’re under 18.',
          ),
        ]),
      ],
    );
  }
}
