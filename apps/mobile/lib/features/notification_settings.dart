import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/push/push_controller.dart';
import '../core/push/push_service.dart';
import 'notification_settings/notification_choices.dart';

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

/// The Notifications group of Settings: this phone's permission, then the choices the server enforces
/// (master switch, messages, social, names; see `notification_choices.dart`). Hidden where push cannot
/// work (web, desktop, builds without Firebase keys).
class NotificationSettingsGroup extends ConsumerWidget {
  const NotificationSettingsGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(pushServiceProvider).supported) {
      return const SizedBox.shrink();
    }
    final push = ref.watch(pushControllerProvider);
    final denied = push.permission == PushPermission.denied;
    Future<void> toggle(bool on) async {
      final controller = ref.read(pushControllerProvider.notifier);
      if (!on) return controller.disable();
      if (push.permission == PushPermission.granted) return controller.enable();
      if (denied) return;
      if (await showPushExplainer(context)) return controller.accept();
      await controller.notNow();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotificationSection('Notifications', [
          SwitchListTile(
            key: const Key('notifications-push'),
            secondary: const Icon(Icons.smartphone_rounded),
            title: const Text(
              'On this phone',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              denied
                  ? 'Off in your phone’s settings. Turn Hiyall on there.'
                  : 'Never shows what a message says',
            ),
            value: push.on,
            onChanged: denied ? null : toggle,
          ),
        ]),
        const NotificationChoices(),
      ],
    );
  }
}
