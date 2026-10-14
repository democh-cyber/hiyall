import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'core/account_state.dart';
import 'core/activity_state.dart';
import 'core/home_prefs.dart';
import 'core/legal_documents.dart';
import 'core/app_info.dart';
import 'core/deep_link.dart';
import 'core/location_sync.dart';
import 'core/state.dart';
import 'features/chat.dart';
import 'features/help_safety.dart';
import 'l10n/l10n.dart';
import 'features/home.dart';
import 'features/legal_screens.dart';
import 'features/live_sync.dart';
import 'features/account_data.dart'
    show DeletionScheduledScreen, PendingDeletionScreen;
import 'features/auth/auth_screens.dart';
import 'features/auth/onboarding_screen.dart';
import 'features/screens.dart';
import 'features/system_screens.dart';
import 'features/profile.dart';
import 'features/pulse.dart';
import 'features/safety.dart';
import 'features/settings.dart';
import 'features/spaces.dart';
import 'features/discovery.dart' show FindPeopleScreen;
import 'features/people_lists.dart';
import 'shared/person_avatar.dart';
import 'shared/widgets.dart';
import 'shared/navigation_dock.dart';

/// Pages a signed-out visitor may open.
const _openRoutes = {
  '/welcome',
  '/login',
  '/signup',
  '/forgot-password',
  '/account-deleted',
};

/// Where each sign-in state belongs. Re-evaluated whenever the session, or an
/// account waiting on email verification, changes. A page someone was sent
/// away from ([uri], defaulting to [location]) is remembered and opened once
/// they are signed in and onboarded, instead of Home.
String? authRedirect(Ref ref, String location, [Uri? uri]) {
  // A retired app version can do nothing but update.
  if (ref.read(upgradeRequiredProvider)) {
    return location == '/update' ? null : '/update';
  }
  final memory = ref.read(deepLinkMemoryProvider);
  final target = _authTarget(ref, location);
  if (target == null) return null;
  memory.remember(uri ?? Uri(path: location));
  if (target == '/home') return memory.take() ?? '/home';
  return target;
}

String? _authTarget(Ref ref, String location) {
  // Legal pages are readable in every state, including signed out and mid-sign-up.
  if (LegalDoc.forPath(location) != null) return null;
  final session = ref.read(sessionProvider);
  final controller = ref.read(sessionProvider.notifier);
  if (controller.booting) return location == '/splash' ? null : '/splash';
  final active = session.asData?.value;
  if (active == null) {
    // Signed in, but the account is scheduled for deletion: only the screen that can keep it.
    if (ref.read(pendingAccountProvider) != null) {
      return location == '/account-deletion' ? null : '/account-deletion';
    }
    if (ref.read(awaitingVerificationProvider) != null) {
      return location == '/verify-email' ? null : '/verify-email';
    }
    // Signed in with the provider but the API could not be reached.
    if (session.hasError && ref.read(authGatewayProvider).currentUser != null) {
      return location == '/splash' ? null : '/splash';
    }
    return _openRoutes.contains(location) ? null : '/welcome';
  }
  if (!active.onboarded) {
    return location == '/onboarding' ? null : '/onboarding';
  }
  if (_openRoutes.contains(location) ||
      const {
        '/onboarding',
        '/verify-email',
        '/splash',
        '/account-deletion',
        '/update',
      }.contains(location)) {
    return '/home';
  }
  return null;
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.listen(awaitingVerificationProvider, (_, _) => refresh.value++);
  ref.listen(pendingAccountProvider, (_, _) => refresh.value++);
  ref.listen(upgradeRequiredProvider, (_, _) => refresh.value++);
  final router = GoRouter(
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) =>
        authRedirect(ref, state.matchedLocation, state.uri),
    errorBuilder: (context, state) => const NotFoundScreen(),
    routes: [
      GoRoute(
        path: '/update',
        builder: (context, state) => const UpdateRequiredScreen(),
      ),
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/signup',
        builder: (context, state) => const SignupScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      for (final doc in LegalDoc.values)
        GoRoute(
          path: doc.path,
          builder: (context, state) => LegalScreen(doc: doc),
        ),
      GoRoute(
        path: '/account-deleted',
        builder: (context, state) => const DeletionScheduledScreen(),
      ),
      GoRoute(
        path: '/account-deletion',
        builder: (context, state) => const PendingDeletionScreen(),
      ),
      GoRoute(
        path: '/verify-email',
        builder: (context, state) => const VerifyEmailScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      // Full-screen creation, outside the dock.
      GoRoute(
        path: '/compose',
        builder: (context, state) => const ComposePostScreen(),
      ),
      GoRoute(
        path: '/story/new',
        builder: (context, state) => const StoryComposerScreen(),
      ),
      GoRoute(
        path: '/spaces/new',
        builder: (context, state) {
          final kind = state.uri.queryParameters['kind'] ?? 'community';
          // Events and Moments (and anything nested under a community) are
          // switched off for V1.
          if (!FeatureFlags.events &&
              (kind != 'community' ||
                  state.uri.queryParameters['parent'] != null)) {
            return const NotFoundScreen();
          }
          return CreateSpaceScreen(
            kind: kind,
            parentId: state.uri.queryParameters['parent'],
          );
        },
      ),
      GoRoute(
        path: '/people',
        builder: (context, state) => const FindPeopleScreen(),
      ),
      // A profile opened from a full-screen page (a space, Find people). The
      // docked '/discover/person/:id' can't be pushed above those pages.
      GoRoute(
        path: '/person/:id',
        builder: (context, state) => Scaffold(
          body: SafeArea(child: PersonScreen(id: state.pathParameters['id']!)),
        ),
      ),
      // Another member's lists, outside the dock so they open above any profile.
      for (final kind in ['followers', 'following'])
        GoRoute(
          path: '/person/:id/$kind',
          builder: (context, state) => Scaffold(
            body: SafeArea(
              child: ConnectionsScreen(
                kind: kind,
                userId: state.pathParameters['id']!,
              ),
            ),
          ),
        ),
      GoRoute(
        path: '/spaces',
        builder: (context, state) => SpacesScreen(
          parentId: state.uri.queryParameters['parent'],
          initialKind: state.uri.queryParameters['kind'],
        ),
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
                builder: (context, state) => SpaceMembersScreen(
                  id: state.pathParameters['id']!,
                  initialState: state.uri.queryParameters['state'],
                ),
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
                // A conversation (Say hi from Discover, a profile's Message, a
                // tap in Chats) glides up and fades in over about 220 ms instead
                // of cutting in; with reduced motion it just appears.
                pageBuilder: (context, state) {
                  final still = MediaQuery.disableAnimationsOf(context);
                  const glide = Duration(milliseconds: 220);
                  return CustomTransitionPage<void>(
                    key: state.pageKey,
                    transitionDuration: still ? Duration.zero : glide,
                    reverseTransitionDuration: still ? Duration.zero : glide,
                    transitionsBuilder: (context, animation, _, child) {
                      if (MediaQuery.disableAnimationsOf(context)) return child;
                      final curved = CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      );
                      return FadeTransition(
                        opacity: curved,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, .04),
                            end: Offset.zero,
                          ).animate(curved),
                          child: child,
                        ),
                      );
                    },
                    child: ConversationScreen(
                      id: state.pathParameters['id']!,
                      peerId: state.uri.queryParameters['peer'] ?? '',
                      peerName: state.uri.queryParameters['name'] ?? 'Chat',
                    ),
                  );
                },
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
                path: 'following',
                builder: (context, state) =>
                    const ConnectionsScreen(kind: 'following'),
              ),
              GoRoute(
                path: 'followers',
                builder: (context, state) =>
                    const ConnectionsScreen(kind: 'followers'),
              ),
              GoRoute(
                path: 'visitors',
                builder: (context, state) => const VisitorsScreen(),
              ),
              GoRoute(
                path: 'stories',
                builder: (context, state) => const MyStoriesScreen(),
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
                path: 'help',
                builder: (context, state) => const HelpSafetyScreen(),
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
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
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

/// Forces a reading direction on every screen. Only tests set it: the app has
/// no right-to-left language yet, so this is how RTL layouts are checked.
@visibleForTesting
final textDirectionOverrideProvider = Provider<TextDirection?>((ref) => null);

class HiyallApp extends ConsumerWidget {
  const HiyallApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direction = ref.watch(textDirectionOverrideProvider);
    return MaterialApp.router(
      title: 'Hiyall',
      debugShowCheckedModeBanner: false,
      theme: hiyallTheme(Brightness.light),
      darkTheme: hiyallTheme(Brightness.dark),
      themeMode: ref.watch(themeProvider),
      // English only for now; see docs/mobile/17-localization.md.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: direction == null
          ? null
          : (context, child) =>
                Directionality(textDirection: direction, child: child!),
      routerConfig: ref.watch(routerProvider),
    );
  }
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

  /// An open conversation (`/chats/<id>`) is immersive: no app header and no
  /// dock, only the conversation's own compact header and composer.
  static bool inConversation(String path) =>
      RegExp(r'^/chats/[^/]+').hasMatch(path);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final immersive = inConversation(path);
    final selected = routes.indexWhere((r) => path.startsWith(r));
    final index = selected < 0 ? 0 : selected;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider).asData?.value;
    final unreadChats = ref.watch(chatUnreadProvider);
    final unreadActivity = ref.watch(
      activityProvider.select((s) => s.asData?.value.unreadLabel ?? '0'),
    );
    final hasUnreadActivity = unreadActivity != '0';
    Widget logo() => Row(
      children: [
        const BrandMark(size: 36),
        const SizedBox(width: 10),
        Flexible(
          // The wordmark is the logo: it keeps its size at large text settings.
          child: Text(
            'hiyall',
            maxLines: 1,
            textScaler: TextScaler.noScaling,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 27,
              letterSpacing: -1.6,
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
        border: BorderDirectional(
          end: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          logo(),
          const SizedBox(height: 38),
          Expanded(child: ListView(children: List.generate(5, destination))),
        ],
      ),
    );
    final header = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: wide ? 32 : 20,
        vertical: wide ? 16 : 8,
      ),
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
                        ? homeGreeting(
                            ref.watch(homeClockProvider)(),
                            profile?.displayName,
                          )
                        : labels[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
          IconButton(
            tooltip: hasUnreadActivity
                ? 'Open notifications, $unreadActivity unread'
                : 'Open notifications',
            onPressed: () => context.go('/notifications'),
            icon: Badge(
              isLabelVisible: hasUnreadActivity,
              label: Text(unreadActivity),
              backgroundColor: VibeColors.lime,
              textColor: VibeColors.ink,
              child: const Icon(Icons.notifications_none_rounded, size: 23),
            ),
          ),
          IconButton(
            tooltip: dark
                ? 'Switch to light appearance'
                : 'Switch to dark appearance',
            onPressed: () => ref.read(themeProvider.notifier).toggle(!dark),
            icon: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 23,
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            label: 'Open your profile',
            button: true,
            child: InkWell(
              onTap: () => context.go('/profile'),
              borderRadius: BorderRadius.circular(18),
              child: PersonAvatar(
                name: profile?.displayName ?? 'K',
                avatarUrl: profile?.avatarUrl,
                userId: profile?.userId ?? '',
                radius: 22,
                cornerRadius: 16,
                initialStyle: const TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      body: LocationSync(
        child: LiveSync(
          // An open conversation draws to the bottom edge itself (its composer
          // keeps clear of the home indicator), so its backdrop is unbroken.
          child: SafeArea(
            bottom: !immersive,
            child: Row(
              children: [
                if (wide) sidebar,
                Expanded(
                  child: Column(
                    children: [
                      if (!immersive) header,
                      Expanded(child: child),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: wide || immersive
          ? null
          : NavigationDock(
              selectedIndex: index,
              profileName: profile?.displayName ?? 'K',
              profilePhoto: avatarProvider(
                profile?.userId ?? '',
                profile?.avatarUrl,
              ),
              newActivity: hasUnreadActivity,
              unreadChats: unreadChats,
              onSelected: (i) => context.go(routes[i]),
            ),
    );
  }
}
