import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'core/activity_state.dart';
import 'core/state.dart';
import 'features/chat.dart';
import 'features/home.dart';
import 'features/live_sync.dart';
import 'features/screens.dart';
import 'features/profile.dart';
import 'features/privacy.dart';
import 'features/pulse.dart';
import 'features/safety.dart';
import 'features/settings.dart';
import 'features/spaces.dart';
import 'features/design_studio.dart';
import 'shared/widgets.dart';
import 'shared/navigation_dock.dart';

final routerProvider = Provider<GoRouter>((ref) {
  bool signedIn() => ref.read(sessionProvider).asData?.value != null;
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/design',
        builder: (context, state) => const DesignStudioScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => ScreenPreview(
              key: ValueKey(state.pathParameters['id']),
              id: state.pathParameters['id']!,
            ),
          ),
        ],
      ),
      // Full-screen creation, outside the dock; signed-out visitors go home.
      GoRoute(
        path: '/compose',
        redirect: (context, state) => signedIn() ? null : '/home',
        builder: (context, state) => const ComposePostScreen(),
      ),
      GoRoute(
        path: '/story/new',
        redirect: (context, state) => signedIn() ? null : '/home',
        builder: (context, state) => const StoryComposerScreen(),
      ),
      GoRoute(
        path: '/spaces/new',
        redirect: (context, state) => signedIn() ? null : '/home',
        builder: (context, state) => CreateSpaceScreen(
          kind: state.uri.queryParameters['kind'] ?? 'community',
          parentId: state.uri.queryParameters['parent'],
        ),
      ),
      GoRoute(
        path: '/spaces',
        builder: (context, state) =>
            SpacesScreen(parentId: state.uri.queryParameters['parent']),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) =>
                SpaceScreen(id: state.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (context, state) =>
                    EditSpaceScreen(id: state.pathParameters['id']!),
              ),
              GoRoute(
                path: 'members',
                builder: (context, state) =>
                    SpaceMembersScreen(id: state.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(path: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/chats',
            builder: (context, state) => const ChatsScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) => ConversationScreen(
                  id: state.pathParameters['id']!,
                  peerId: state.uri.queryParameters['peer'] ?? '',
                  peerName: state.uri.queryParameters['name'] ?? 'Chat',
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/discover',
            builder: (context, state) => const DiscoverScreen(),
            routes: [
              GoRoute(
                path: 'person/:id',
                builder: (context, state) =>
                    PersonScreen(id: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (context, state) => const EditProfileScreen(),
              ),
              GoRoute(
                path: 'privacy',
                builder: (context, state) => const PrivacyScreen(),
              ),
              GoRoute(
                path: 'devices',
                builder: (context, state) => const ChatDevicesScreen(),
              ),
              GoRoute(
                path: 'sessions',
                builder: (context, state) => const SessionsScreen(),
              ),
              GoRoute(
                path: 'controls',
                builder: (context, state) => const ControlsScreen(),
              ),
              GoRoute(
                path: 'settings',
                builder: (context, state) => const SettingsScreen(),
              ),
              GoRoute(
                path: 'reports',
                builder: (context, state) => const ReportsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
final themeProvider = NotifierProvider<ThemeController, ThemeMode>(
  ThemeController.new,
);

/// The appearance choice, kept on this device.
class ThemeController extends Notifier<ThemeMode> {
  static const _key = 'appearance';
  static const _storage = FlutterSecureStorage();

  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.system;
  }

  Future<void> _restore() async {
    try {
      final saved = await _storage.read(key: _key);
      final mode = ThemeMode.values.where((m) => m.name == saved).firstOrNull;
      if (mode != null) state = mode;
    } catch (_) {
      // No platform storage (tests, some desktops): stay on system.
    }
  }

  void set(ThemeMode mode) {
    state = mode;
    _storage.write(key: _key, value: mode.name).catchError((_) {});
  }

  void toggle(bool dark) => set(dark ? ThemeMode.dark : ThemeMode.light);
  void useSystem() => set(ThemeMode.system);
}

class KairovaApp extends ConsumerWidget {
  const KairovaApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Kairova',
    debugShowCheckedModeBanner: false,
    theme: kairovaTheme(Brightness.light),
    darkTheme: kairovaTheme(Brightness.dark),
    themeMode: ref.watch(themeProvider),
    routerConfig: ref.watch(routerProvider),
  );
}

class AppShell extends ConsumerWidget {
  final String path;
  final Widget child;
  const AppShell({super.key, required this.path, required this.child});
  static const routes = [
    '/home',
    '/chats',
    '/discover',
    '/notifications',
    '/profile',
  ];
  static const labels = [
    'Home',
    'Chats',
    'Discover',
    'Notifications',
    'Profile',
  ];
  static const icons = [
    Icons.home_rounded,
    Icons.chat_bubble_outline_rounded,
    Icons.explore_outlined,
    Icons.notifications_none_rounded,
    Icons.person_outline_rounded,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(sessionProvider).asData?.value == null) {
      return const WelcomeScreen();
    }
    final selected = routes.indexWhere((r) => path.startsWith(r));
    final index = selected < 0 ? 0 : selected;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider).asData?.value;
    final unreadChats = ref.watch(chatUnreadProvider);
    final unreadActivity = ref.watch(
      activityProvider.select((s) => s.asData?.value.unread ?? 0),
    );
    final avatar = profile?.displayName.characters.first ?? 'K';
    Widget logo() => Row(
      children: [
        const BrandMark(size: 38),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            'kairova',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 29,
              letterSpacing: -1.7,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
    Widget destination(int i) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: index == i,
        button: true,
        child: InkWell(
          onTap: () => context.go(routes[i]),
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
            decoration: BoxDecoration(
              color: index == i ? VibeColors.ink : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                Icon(
                  icons[i],
                  size: 23,
                  color: index == i ? VibeColors.lime : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      color: index == i
                          ? Colors.white
                          : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (index == i)
                  const Icon(
                    Icons.arrow_outward_rounded,
                    color: VibeColors.lime,
                    size: 16,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final sidebar = Container(
      width: 238,
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          logo(),
          const SizedBox(height: 38),
          Padding(
            padding: const EdgeInsets.only(left: 14, bottom: 16),
            child: Text(
              'YOUR DAILY ORBIT',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 10,
                letterSpacing: 1.3,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: ListView(children: List.generate(5, destination))),
          if (MediaQuery.sizeOf(context).height > 640 &&
              MediaQuery.textScalerOf(context).scale(1) < 1.4) ...[
            VibePanel(
              color: VibeColors.lilac,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.auto_awesome_rounded, color: VibeColors.ink),
                  const SizedBox(height: 18),
                  const Text(
                    'A little more you.\nA lot less noise.',
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 21,
                      height: 1.1,
                      color: VibeColors.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.go('/profile/privacy'),
                    style: TextButton.styleFrom(
                      foregroundColor: VibeColors.ink,
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text('Make it your space')),
                        SizedBox(width: 4),
                        Icon(Icons.arrow_outward_rounded, size: 14),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
          Text(
            'KAIROVA / EARLY ACCESS',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 9,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
    final header = Padding(
      padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 18, vertical: 16),
      child: Row(
        children: [
          if (!wide)
            Expanded(child: logo())
          else
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    index == 0
                        ? 'Hey, ${profile?.displayName ?? 'you'}'
                        : labels[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'YOUR SPACE. YOUR FREQUENCY.',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (wide)
            IconButton(
              tooltip: 'Explore all screen designs',
              onPressed: () => context.go('/design'),
              icon: const Icon(Icons.design_services_outlined, size: 21),
            ),
          IconButton(
            tooltip: unreadActivity > 0
                ? 'Open notifications, $unreadActivity unread'
                : 'Open notifications',
            onPressed: () => context.go('/notifications'),
            icon: Badge(
              isLabelVisible: unreadActivity > 0,
              label: Text(unreadActivity > 99 ? '99+' : '$unreadActivity'),
              backgroundColor: VibeColors.lime,
              textColor: VibeColors.ink,
              child: const Icon(Icons.notifications_none_rounded, size: 21),
            ),
          ),
          IconButton(
            tooltip: dark
                ? 'Switch to light appearance'
                : 'Switch to dark appearance',
            onPressed: () => ref.read(themeProvider.notifier).toggle(!dark),
            icon: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 21,
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            label: 'Open your profile',
            button: true,
            child: InkWell(
              onTap: () => context.go('/profile'),
              borderRadius: BorderRadius.circular(18),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VibeColors.lilac,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  avatar,
                  style: const TextStyle(
                    color: VibeColors.ink,
                    fontFamily: 'SpaceGrotesk',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      body: LiveSync(
        child: SafeArea(
          child: Row(
            children: [
              if (wide) sidebar,
              Expanded(
                child: Column(
                  children: [
                    header,
                    Expanded(child: child),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: path == '/home'
          ? FloatingActionButton(
              tooltip: 'Make a little space',
              backgroundColor: VibeColors.lime,
              foregroundColor: VibeColors.ink,
              elevation: 2,
              onPressed: () => showCreateSheet(context),
              child: const Icon(Icons.auto_awesome_rounded),
            )
          : null,
      bottomNavigationBar: wide
          ? null
          : NavigationDock(
              selectedIndex: index,
              profileName: profile?.displayName ?? 'K',
              newActivity: unreadActivity > 0,
              unreadChats: unreadChats,
              onSelected: (i) => context.go(routes[i]),
            ),
    );
  }
}
