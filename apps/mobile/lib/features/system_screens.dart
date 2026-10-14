import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_info.dart';
import '../shared/widgets.dart';

/// A full-screen, centred message with the brand mark: the frame for the
/// 404 page and the update screen.
class _SystemPage extends StatelessWidget {
  final String title, body;
  final List<Widget> actions;
  const _SystemPage({
    required this.title,
    required this.body,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: BrandMark(size: 64)),
                const SizedBox(height: 28),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    height: 1.6,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Any link the app does not know (an old share, a typo in a web URL).
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});
  @override
  Widget build(BuildContext context) => _SystemPage(
    title: 'This page wandered off',
    body: 'The link may be old or mistyped. Nothing’s wrong with your account.',
    actions: [
      FilledButton(
        key: const Key('not-found-home'),
        onPressed: () => context.go('/home'),
        child: const Text('Go to Home'),
      ),
    ],
  );
}

/// Which store page the update button opens on this platform.
String storeUrlFor({bool? web, TargetPlatform? platform}) {
  if (web ?? kIsWeb) return '';
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => AppInfo.appStoreUrl,
    TargetPlatform.android => AppInfo.playStoreUrl,
    _ => '',
  };
}

/// Shown, and nothing else, once the server refuses this app version
/// (HTTP 426, code UPGRADE_REQUIRED). There is no way back into the app:
/// an old build may hold a broken chat protocol.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = storeUrlFor();
    return PopScope(
      canPop: false,
      child: _SystemPage(
        title: 'Update Hiyall',
        body: kIsWeb
            ? 'A newer version of Hiyall is out. Reload this page to get it.'
            : 'This version of Hiyall is no longer supported. Get the latest '
                  'from the store to keep chatting. Your account and chats are safe.',
        actions: [
          if (store.isNotEmpty)
            FilledButton.icon(
              key: const Key('update-open-store'),
              icon: const Icon(Icons.system_update_rounded),
              label: const Text('Update now'),
              onPressed: () async {
                final ok = await launchUrl(
                  Uri.parse(store),
                  mode: LaunchMode.externalApplication,
                ).catchError((_) => false);
                if (!ok && context.mounted) {
                  showMessage(
                    context,
                    'Couldn’t open the store. Search for Hiyall there instead.',
                  );
                }
              },
            ),
          const SizedBox(height: 12),
          Text(
            'You have version ${AppInfo.display}.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
