import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/api.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import 'safety.dart';

/// "Just now", "5 min ago", "3 h ago", "2 days ago", then a date.
String timeAgo(DateTime at, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inMinutes < 2) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
  final l = at.toLocal();
  return '${l.day}/${l.month}/${l.year}';
}

class _Back extends StatelessWidget {
  final String label, to;
  const _Back(this.label, this.to);
  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton.icon(
      onPressed: () => context.go(to),
      icon: const Icon(Icons.arrow_back),
      label: Text(label),
    ),
  );
}

class _Group extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Group(this.title, this.children);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
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
        VibePanel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      ],
    ),
  );
}

class _Link extends StatelessWidget {
  final IconData icon;
  final String title, subtitle, to;
  const _Link(this.icon, this.title, this.subtitle, this.to);
  @override
  Widget build(BuildContext context) => ListTile(
    key: Key('settings-$to'),
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => context.go(to),
  );
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool busy = false;

  Future<void> signOut() async {
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

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeProvider);
    return ReadingWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        children: [
          const _Back('Profile', '/profile'),
          Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
          const _Group('Account', [
            _Link(
              Icons.face_6_outlined,
              'Edit profile',
              'Name, bio, interests and style',
              '/profile/edit',
            ),
            _Link(
              Icons.devices_outlined,
              'Where you’re signed in',
              'See sessions and sign out remotely',
              '/profile/sessions',
            ),
            _Link(
              Icons.phonelink_lock_outlined,
              'Chat devices',
              'Phones that hold your chat keys',
              '/profile/devices',
            ),
          ]),
          const _Group('Privacy and safety', [
            _Link(
              Icons.shield_outlined,
              'Privacy',
              'Who can see, find and message you',
              '/profile/privacy',
            ),
            _Link(
              Icons.block_rounded,
              'Blocked, muted and restricted',
              'People you’ve limited',
              '/profile/controls',
            ),
            _Link(
              Icons.flag_outlined,
              'Your reports',
              'Status of reports you sent',
              '/profile/reports',
            ),
          ]),
          _Group('Appearance', [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  key: const Key('theme-choice'),
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) =>
                      ref.read(themeProvider.notifier).set(s.single),
                ),
              ),
            ),
          ]),
          _Group('About', [
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text(
                'About Kairova',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('0.1.0 · Early access'),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'Kairova',
                applicationVersion: '0.1.0 · Early access',
                applicationIcon: const BrandMark(),
              ),
            ),
            const _Link(
              Icons.design_services_outlined,
              'Design gallery',
              'Every screen design in one place',
              '/design',
            ),
          ]),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            key: const Key('sign-out'),
            onPressed: busy ? null : signOut,
            icon: const Icon(Icons.logout_rounded),
            label: Text(busy ? 'Signing out…' : 'Sign out'),
          ),
        ],
      ),
    );
  }
}

/// Live sessions on the account: this one first, then the rest, each of which
/// can be signed out remotely.
class SessionsScreen extends ConsumerStatefulWidget {
  const SessionsScreen({super.key});
  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  List<Map<String, dynamic>>? items;
  String? next;
  Object? error;
  bool busy = false;

  Session get session => ref.read(sessionProvider).asData!.value!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Future<void> load({bool more = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await ref
          .read(apiProvider)
          .sessions(session, more ? next : null);
      final page = (data['items'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        items = [...more ? items ?? const [] : const [], ...page];
        next = data['nextCursor'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> revoke(String id) async {
    setState(() => busy = true);
    try {
      await ref.read(apiProvider).revokeSession(session, id);
      if (!mounted) return;
      setState(() => items?.removeWhere((s) => s['sessionId'] == id));
      showMessage(context, 'Signed out of that session.');
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> revokeOthers() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out everywhere else?'),
        content: const Text(
          'Every other session ends now. Your chats stay on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-revoke-others'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out others'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => busy = true);
    try {
      final count = await ref.read(apiProvider).revokeOtherSessions(session);
      if (!mounted) return;
      setState(() => items?.removeWhere((s) => s['current'] != true));
      showMessage(
        context,
        count == 1
            ? 'Signed out of 1 session.'
            : 'Signed out of $count sessions.',
      );
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  static (IconData, String) describe(String? platform) => switch (platform) {
    'android' => (Icons.android_rounded, 'Android'),
    'ios' => (Icons.phone_iphone_rounded, 'iPhone'),
    'web' => (Icons.language_rounded, 'Web browser'),
    _ => (Icons.devices_other_rounded, 'Unknown device'),
  };

  Widget tile(Map<String, dynamic> s) {
    final scheme = Theme.of(context).colorScheme;
    final current = s['current'] == true;
    final (icon, name) = describe(s['platform'] as String?);
    final seen = DateTime.parse(s['lastSeenAt'] as String);
    final started = DateTime.parse(s['createdAt'] as String);
    return ListTile(
      key: Key('session-${s['sessionId']}'),
      leading: CircleAvatar(
        backgroundColor: current ? VibeColors.lime : VibeColors.mint,
        foregroundColor: VibeColors.ink,
        child: Icon(icon),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          if (current) ...[
            const SizedBox(width: 8),
            const VibeTag('THIS DEVICE', color: VibeColors.lime),
          ],
        ],
      ),
      subtitle: Text(
        current
            ? 'Active now · signed in ${timeAgo(started)}'
            : 'Last active ${timeAgo(seen)} · signed in ${timeAgo(started)}',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: current
          ? null
          : TextButton(
              onPressed: busy ? null : () => revoke(s['sessionId'] as String),
              child: const Text('Sign out'),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    final ordered = list == null
        ? null
        : [
            ...list.where((s) => s['current'] == true),
            ...list.where((s) => s['current'] != true),
          ];
    final others = ordered?.where((s) => s['current'] != true).length ?? 0;
    return ReadingWidth(
      child: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            const _Back('Settings', '/profile/settings'),
            Text(
              'Where you’re signed in',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Don’t recognise one? Sign it out. Sessions end on their own when they expire.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            if (error != null)
              FailureCard(error: error!, retry: load)
            else if (ordered == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              VibePanel(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: [for (final s in ordered) tile(s)]),
              ),
              if (next != null)
                TextButton(
                  onPressed: busy ? null : () => load(more: true),
                  child: const Text('Show more'),
                ),
              if (others > 0) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('revoke-others'),
                  onPressed: busy ? null : revokeOthers,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Sign out everywhere else'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Reports this account sent and where each one stands.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  List<Map<String, dynamic>>? items;
  String? next;
  Object? error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Future<void> load({bool more = false}) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await ref
          .read(apiProvider)
          .myReports(
            ref.read(sessionProvider).asData!.value!,
            more ? next : null,
          );
      if (!mounted) return;
      setState(() {
        items = [...more ? items ?? const [] : const [], ...page.items];
        next = page.nextCursor;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  static (String, Color) status(String value) => switch (value) {
    'actioned' => ('Action taken', VibeColors.lime),
    'dismissed' => ('No violation found', VibeColors.lilac),
    _ => ('In review', VibeColors.peach),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = items;
    return ReadingWidth(
      child: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            const _Back('Settings', '/profile/settings'),
            Text(
              'Your reports',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'The people you report never see who reported them.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            if (error != null)
              FailureCard(error: error!, retry: load)
            else if (list == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (list.isEmpty)
              const EmptyCard(
                icon: Icons.flag_outlined,
                title: 'No reports',
                description: 'If something doesn’t feel right, report it from a profile or a chat.',
              )
            else
              VibePanel(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    for (final r in list)
                      Builder(
                        builder: (context) {
                          final (label, color) = status(r['status'] as String);
                          final subject = r['subject'] as Map;
                          final name =
                              (subject['displayName'] as String? ?? '')
                                  .trim()
                                  .isEmpty
                              ? '@${subject['username']}'
                              : subject['displayName'] as String;
                          final what = switch (r['targetType']) {
                            'conversation' => 'Chat with $name',
                            'message' => 'Message from $name',
                            _ => name,
                          };
                          return ListTile(
                            key: Key('report-${r['reportId']}'),
                            title: Text(
                              what,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${reportReasons[r['reasonCode']] ?? r['reasonCode']} · ${timeAgo(DateTime.parse(r['createdAt'] as String))}',
                            ),
                            trailing: VibeTag(
                              label.toUpperCase(),
                              color: color,
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            if (next != null)
              TextButton(
                onPressed: loading ? null : () => load(more: true),
                child: const Text('Show more'),
              ),
          ],
        ),
      ),
    );
  }
}
