import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../shared/profile_space.dart';
import 'profile_editor.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileState();
}

class _ProfileState extends ConsumerState<ProfileScreen> {
  bool busy = false;
  Future<void> logout() async {
    setState(() => busy = true);
    try {
      await ref.read(sessionProvider.notifier).logout();
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Your space, your rules.',
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Close before navigation so settings never overlay the destination.
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Privacy & visibility'),
                  onTap: () {
                    Navigator.pop(sheet);
                    context.go('/profile/privacy');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.devices_outlined),
                  title: const Text('Active sessions'),
                  onTap: () {
                    Navigator.pop(sheet);
                    context.go('/profile/sessions');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.phonelink_lock_outlined),
                  title: const Text('Chat devices'),
                  onTap: () {
                    Navigator.pop(sheet);
                    context.go('/profile/devices');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Profile signature'),
                  onTap: () {
                    Navigator.pop(sheet);
                    context.go('/profile/edit');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.dark_mode_outlined),
                  title: const Text('Appearance'),
                  onTap: () {
                    Navigator.pop(sheet);
                    ref
                        .read(themeProvider.notifier)
                        .toggle(
                          Theme.of(context).brightness != Brightness.dark,
                        );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.design_services_outlined),
                  title: const Text('Explore all screen designs'),
                  onTap: () {
                    Navigator.pop(sheet);
                    context.go('/design');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About Kairova'),
                  onTap: () {
                    Navigator.pop(sheet);
                    showAboutDialog(
                      context: context,
                      applicationName: 'Kairova',
                      applicationVersion: '0.1.0 · Early access',
                      applicationIcon: const BrandMark(),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.logout_rounded),
                  title: Text(busy ? 'Signing out…' : 'Sign out'),
                  onTap: busy
                      ? null
                      : () {
                          Navigator.pop(sheet);
                          logout();
                        },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(profileProvider)
      .when(
        data: (profile) => ProfileSpace(
          profile: profile,
          isOwner: true,
          onEdit: () => context.go('/profile/edit'),
          onSettings: openSettings,
        ),
        loading: () => const ProfileSkeleton(),
        error: (e, s) => ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              FailureCard(
                error: e,
                retry: () => ref.invalidate(profileProvider),
              ),
            ],
          ),
        ),
      );
}

class EditProfileScreen extends ConsumerWidget {
  const EditProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ReadingWidth(
    child: ref
        .watch(profileProvider)
        .when(
          data: (profile) => ProfileForm(
            key: ValueKey('${profile.userId}:${profile.version}'),
            profile: profile,
          ),
          loading: () => const VibeLoading(),
          error: (e, s) => FailureCard(
            error: e,
            retry: () => ref.invalidate(profileProvider),
          ),
        ),
  );
}

class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});
  @override
  ConsumerState<SessionsScreen> createState() => _SessionsState();
}

class _SessionsState extends ConsumerState<SessionsScreen> {
  bool busy = false;
  final more = <Map<String, dynamic>>[];
  String? next;
  bool initialized = false;
  Future<void> revoke(String id) async {
    setState(() => busy = true);
    try {
      await ref
          .read(apiProvider)
          .revokeSession(ref.read(sessionProvider).asData!.value!, id);
      more.clear();
      initialized = false;
      ref.invalidate(sessionsProvider);
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loadMore() async {
    if (next == null || busy) return;
    setState(() => busy = true);
    try {
      final data = await ref
          .read(apiProvider)
          .sessions(ref.read(sessionProvider).asData!.value!, next);
      if (mounted) {
        setState(() {
          more.addAll((data['items'] as List).cast<Map<String, dynamic>>());
          next = data['nextCursor'] as String?;
        });
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ReadingWidth(
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => context.go('/profile'),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Profile'),
          ),
        ),
        const PageHeader(
          eyebrow: 'Account access',
          title: 'Your sessions',
          subtitle: 'Revoke any session you no longer need. Sign out from Profile to end this session.',
        ),
        ref
            .watch(sessionsProvider)
            .when(
              data: (data) {
                if (!initialized) {
                  next = data['nextCursor'] as String?;
                  initialized = true;
                }
                final items = [
                  ...(data['items'] as List).cast<Map<String, dynamic>>(),
                  ...more,
                ];
                return Column(
                  children: [
                    for (final s in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: VibePanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 14,
                                runSpacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: VibeColors.mint,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: const Icon(
                                      Icons.devices_rounded,
                                      color: VibeColors.ink,
                                    ),
                                  ),
                                  Text(
                                    s['current'] == true
                                        ? 'This session'
                                        : 'Account session',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  VibeTag(
                                    s['revokedAt'] != null
                                        ? 'Revoked'
                                        : (DateTime.parse(
                                                s['expiresAt'] as String,
                                              ).isBefore(DateTime.now())
                                              ? 'Expired'
                                              : 'Active'),
                                    color: s['revokedAt'] != null
                                        ? VibeColors.pink
                                        : VibeColors.lime,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'Started ${DateTime.parse(s['createdAt'] as String).toLocal().toString().split('.')[0]}',
                              ),
                              Text(
                                'Expires ${DateTime.parse(s['expiresAt'] as String).toLocal().toString().split('.')[0]}',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                              if (s['current'] != true &&
                                  s['revokedAt'] == null) ...[
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => revoke(s['sessionId'] as String),
                                  icon: const Icon(Icons.logout, size: 18),
                                  label: const Text('Revoke session'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    if (next != null)
                      TextButton(
                        onPressed: busy ? null : loadMore,
                        child: const Text('Load more'),
                      ),
                  ],
                );
              },
              error: (e, s) => FailureCard(
                error: e,
                retry: () {
                  initialized = false;
                  more.clear();
                  ref.invalidate(sessionsProvider);
                },
              ),
              loading: () => const VibeLoading(),
            ),
      ],
    ),
  );
}
