import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/push/push_controller.dart';
import '../core/push/push_service.dart';
import '../shared/widgets.dart';

/// The short explainer shown before the system's permission dialog. True means
/// "Turn on"; "Not now" and dismissing the sheet are false.
Future<bool> showPushExplainer(BuildContext context) async {
  final turnOn = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Know when someone writes back?',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            const Text(
              'Hiyall can nudge you about new messages, friend requests and '
              'followers. A notification never shows what a message says. '
              'You can turn it off any time in Settings.',
            ),
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('push-explainer-accept'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Turn on'),
            ),
            TextButton(
              key: const Key('push-explainer-not-now'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    ),
  );
  return turnOn ?? false;
}

/// Starts push for the signed-in app and shows the explainer when the
/// controller asks for it (after the first message sent or first follow).
/// Sits in the app shell, where a navigator is above it.
class PushHost extends ConsumerStatefulWidget {
  final Widget child;
  const PushHost({super.key, required this.child});
  @override
  ConsumerState<PushHost> createState() => _PushHostState();
}

class _PushHostState extends ConsumerState<PushHost> {
  bool showing = false;

  @override
  void initState() {
    super.initState();
    // Reading it starts it; it does nothing where push is unsupported.
    ref.read(pushControllerProvider);
  }

  Future<void> show() async {
    if (showing || !mounted) return;
    showing = true;
    final controller = ref.read(pushControllerProvider.notifier);
    final turnOn = await showPushExplainer(context);
    showing = false;
    await (turnOn ? controller.accept() : controller.notNow());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pushControllerProvider.select((s) => s.explainerDue), (_, due) {
      if (due) WidgetsBinding.instance.addPostFrameCallback((_) => show());
    });
    return widget.child;
  }
}

/// The Notifications group of Settings. Hidden where push cannot work (web,
/// desktop, builds without Firebase keys).
class NotificationSettingsGroup extends ConsumerWidget {
  const NotificationSettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(pushServiceProvider).supported) {
      return const SizedBox.shrink();
    }
    final push = ref.watch(pushControllerProvider);
    final prefs = ref.watch(notificationPrefsProvider).asData?.value;
    final denied = push.permission == PushPermission.denied;
    Future<void> toggle(bool on) async {
      final controller = ref.read(pushControllerProvider.notifier);
      if (!on) return controller.disable();
      if (push.permission == PushPermission.granted) return controller.enable();
      if (denied) return;
      if (await showPushExplainer(context)) return controller.accept();
      await controller.notNow();
    }

    Future<void> choose(String key, bool on) async {
      try {
        await ref.read(pushBackendProvider).setPrefs({key: on});
      } catch (_) {}
      ref.invalidate(notificationPrefsProvider);
    }

    final live = push.on;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Semantics(
              header: true,
              child: Text(
                'NOTIFICATIONS',
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
            child: Column(
              children: [
                SwitchListTile(
                  key: const Key('notifications-push'),
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text(
                    'Push notifications',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    denied
                        ? 'Off in your phone’s settings. Turn Hiyall on there.'
                        : 'Never shows what a message says',
                  ),
                  value: live,
                  onChanged: denied ? null : toggle,
                ),
                SwitchListTile(
                  key: const Key('notifications-chat'),
                  secondary: const Icon(Icons.chat_bubble_outline_rounded),
                  title: const Text(
                    'Messages',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('When someone writes to you'),
                  value: prefs?['chat'] ?? true,
                  onChanged: live && prefs != null
                      ? (on) => unawaited(choose('chat', on))
                      : null,
                ),
                SwitchListTile(
                  key: const Key('notifications-social'),
                  secondary: const Icon(Icons.favorite_border_rounded),
                  title: const Text(
                    'Friends and followers',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Friend requests, new followers, space invitations',
                  ),
                  value: prefs?['social'] ?? true,
                  onChanged: live && prefs != null
                      ? (on) => unawaited(choose('social', on))
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
