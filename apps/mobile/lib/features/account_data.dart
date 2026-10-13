import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart' show routerProvider;
import '../core/account_state.dart';
import '../core/api.dart';
import '../core/auth/auth_gateway.dart';
import '../core/data_delivery.dart';
import '../core/state.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart';
import 'auth/auth_widgets.dart' show AuthError, PasswordField;

// Settings, Your data: "Download my data" and "Delete account", the screens
// they open, and the screen a member lands on while their account is scheduled
// for deletion. The server enforces everything here (docs/api/22-account-deletion-and-export.md).

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "12 Nov 2026" in the member's own time zone.
String deletionDate(DateTime at) {
  final l = at.toLocal();
  return '${l.day} ${_months[l.month - 1]} ${l.year}';
}

/// "about 5 hours" / "about 40 minutes", for a limit that says when it lifts.
String waitWords(Duration wait) {
  final minutes = (wait.inSeconds / 60).ceil();
  if (minutes < 90) return minutes <= 1 ? 'a minute' : '$minutes minutes';
  final hours = (minutes / 60).round();
  return hours == 1 ? 'an hour' : '$hours hours';
}

/// The file name of an export made at [at].
String exportFilename(DateTime at) {
  final u = at.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'hiyall-data-${u.year}-${two(u.month)}-${two(u.day)}.json';
}

Duration _motion(BuildContext context, [int ms = 200]) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: ms);

/// A settings row with the app's press feedback (no grey ink) and a 56 dp target.
class _DataRow extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final bool danger;
  final Widget? trailing;
  const _DataRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final color = danger ? tokens.error : tokens.text;
    return PressScale(
      onTap: onTap,
      minHeight: 56,
      borderRadius: BorderRadius.circular(16),
      highlight: tokens.hairline.withValues(alpha: .35),
      semanticLabel: '$title. $subtitle',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontWeight: FontWeight.w700, color: color),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

/// The "Your data" group of Settings.
class AccountDataSettingsGroup extends ConsumerStatefulWidget {
  const AccountDataSettingsGroup({super.key});
  @override
  ConsumerState<AccountDataSettingsGroup> createState() =>
      _AccountDataGroupState();
}

class _AccountDataGroupState extends ConsumerState<AccountDataSettingsGroup> {
  bool busy = false;
  final rowKey = GlobalKey();

  void say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> download() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (busy || session == null) return;
    // Anchors the share sheet on iPad.
    final box = rowKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    setState(() => busy = true);
    try {
      final bytes = await ref.read(apiProvider).exportData(session);
      final how = await ref.read(dataDeliveryProvider)(
        exportFilename(DateTime.now()),
        bytes,
        origin: origin,
      );
      say(
        how == Delivery.downloaded
            ? 'Your data was downloaded.'
            : 'Your data is ready. Choose where to keep it.',
      );
    } on ApiFailure catch (error) {
      final wait = error.retryAfter;
      say(
        error.code == 'RATE_LIMITED' && wait != null
            ? 'You can download your data once a day. Try again in about ${waitWords(wait)}.'
            : error.displayMessage,
      );
    } catch (_) {
      say('Couldn’t download your data. Try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void deleteAccount() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const DeleteAccountScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              'YOUR DATA',
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
              KeyedSubtree(
                key: rowKey,
                child: _DataRow(
                  key: const Key('download-data'),
                  icon: Icons.download_rounded,
                  title: 'Download my data',
                  subtitle: busy
                      ? 'Preparing your file…'
                      : 'A copy of what Hiyall holds about you',
                  onTap: busy ? null : download,
                  trailing: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
              ),
              _DataRow(
                key: const Key('delete-account'),
                icon: Icons.delete_outline_rounded,
                title: 'Delete account',
                subtitle: 'Hidden now, gone for good after 30 days',
                onTap: deleteAccount,
                danger: true,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

enum _Step { explain, confirm, reauth }

/// Deleting the account in a few calm steps: what happens, type the username,
/// confirm it's you when the server asks, then sign out.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});
  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  _Step step = _Step.explain;
  final username = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String? error;
  late final Session session = ref.read(sessionProvider).asData!.value!;

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  String get typed => username.text.trim().replaceFirst('@', '').toLowerCase();
  String? get ownUsername => ref.read(profileProvider).asData?.value.username;

  /// The server checks the username too; this only keeps the button honest.
  bool get matches =>
      ownUsername != null && typed == ownUsername!.toLowerCase();

  void go(_Step next) => setState(() {
    step = next;
    error = null;
  });

  Future<void> schedule() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final status = await ref
          .read(apiProvider)
          .scheduleDeletion(session, typed);
      // Every session ended on the server; leave this one too, quietly, and say when it ends.
      ref.read(deletionScheduledProvider.notifier).set(status.dueAt);
      final router = ref.read(routerProvider);
      await ref.read(sessionProvider.notifier).signOutProvider();
      router.go('/account-deleted');
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      if (failure.code == 'REAUTH_REQUIRED') {
        go(_Step.reauth);
      } else {
        setState(() => error = failure.displayMessage);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Something went wrong. Try again.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirmItsYou() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref
          .read(reauthenticatorProvider)
          .reauthenticate(password: password.text);
      // The new sign-in time travels in a fresh token.
      await ref.read(authGatewayProvider).refreshToken();
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          if (!failure.cancelled) error = failure.message;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Couldn’t confirm it’s you. Try again.';
        });
      }
      return;
    }
    if (mounted) setState(() => busy = false);
    await schedule();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final text = Theme.of(context).textTheme;
    final title = switch (step) {
      _Step.explain => 'Delete your account?',
      _Step.confirm => 'Type your username',
      _Step.reauth => 'Confirm it’s you',
    };
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(
          backgroundColor: tokens.bg,
          automaticallyImplyLeading: false,
          leading: IconButton(
            key: const Key('delete-close'),
            tooltip: 'Close',
            onPressed: busy ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: AnimatedSwitcher(
                  duration: _motion(context),
                  child: Column(
                    key: ValueKey(step),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        step == _Step.explain ? 'Step 1 of 2' : 'Step 2 of 2',
                        style: TextStyle(
                          fontSize: 13,
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: text.headlineMedium?.copyWith(
                            color: tokens.text,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      ...switch (step) {
                        _Step.explain => _explain(tokens),
                        _Step.confirm => _confirm(tokens),
                        _Step.reauth => _reauth(tokens),
                      },
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _point(ChatTokens tokens, IconData icon, String title, String body) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tokens.accent, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: TextStyle(height: 1.5, color: tokens.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  List<Widget> _explain(ChatTokens tokens) => [
    _point(
      tokens,
      Icons.visibility_off_outlined,
      'You disappear right away',
      'You’re signed out everywhere and hidden from Discover, Nearby, chats and search.',
    ),
    _point(
      tokens,
      Icons.hourglass_bottom_rounded,
      'You have 30 days to change your mind',
      'Sign in any time in that window and tap “Keep my account”. Everything comes back as it was. After that it can’t be undone.',
    ),
    _point(
      tokens,
      Icons.delete_sweep_outlined,
      'What gets deleted',
      'Your profile, posts, stories, photos, follows, friends and conversations. A few records stay where safety or the law needs them, like an open report.',
    ),
    _point(
      tokens,
      Icons.lock_outline_rounded,
      'Your chat messages',
      'They’re end-to-end encrypted and live only on your devices, so we can’t read or restore them. The conversations are removed from our servers; copies on your devices go when you sign out or remove the app.',
    ),
    const SizedBox(height: 6),
    FilledButton(
      key: const Key('delete-continue'),
      onPressed: () => go(_Step.confirm),
      child: const Text('Continue'),
    ),
    const SizedBox(height: 8),
    TextButton(
      key: const Key('delete-keep'),
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Keep my account'),
    ),
  ];

  List<Widget> _confirm(ChatTokens tokens) {
    final name = ownUsername;
    return [
      Text(
        name == null
            ? 'Type your username to confirm.'
            : 'To confirm, type your username, @$name.',
        style: TextStyle(height: 1.5, color: tokens.textSecondary),
      ),
      const SizedBox(height: 18),
      TextField(
        key: const Key('delete-username'),
        controller: username,
        enabled: !busy,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() => error = null),
        onSubmitted: (_) => matches && !busy ? schedule() : null,
        decoration: const InputDecoration(labelText: 'Your username'),
      ),
      const SizedBox(height: 18),
      AuthError(error),
      FilledButton(
        key: const Key('delete-confirm'),
        style: FilledButton.styleFrom(
          backgroundColor: tokens.error,
          foregroundColor: Colors.white,
        ),
        onPressed: matches && !busy ? schedule : null,
        child: Text(busy ? 'Deleting…' : 'Delete my account'),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: busy ? null : () => go(_Step.explain),
        child: const Text('Back'),
      ),
    ];
  }

  List<Widget> _reauth(ChatTokens tokens) {
    final method = ref.read(reauthenticatorProvider).method;
    final provider = switch (method) {
      AuthMethod.google => 'Google',
      AuthMethod.facebook => 'Facebook',
      AuthMethod.apple => 'Apple',
      _ => null,
    };
    return [
      Text(
        method == AuthMethod.password
            ? 'For your security, enter your password once more.'
            : provider != null
            ? 'For your security, sign in with $provider once more.'
            : 'For your security, sign out and sign back in, then try again.',
        style: TextStyle(height: 1.5, color: tokens.textSecondary),
      ),
      const SizedBox(height: 18),
      if (method == AuthMethod.password) ...[
        PasswordField(
          key: const Key('delete-password'),
          controller: password,
          enabled: !busy,
          onSubmitted: confirmItsYou,
        ),
        const SizedBox(height: 18),
      ],
      AuthError(error),
      if (method == AuthMethod.password || provider != null)
        FilledButton(
          key: const Key('delete-reauth'),
          onPressed: busy ? null : confirmItsYou,
          child: Text(
            busy
                ? 'Confirming…'
                : provider != null
                ? 'Continue with $provider'
                : 'Confirm',
          ),
        )
      else
        FilledButton(
          key: const Key('delete-sign-out'),
          onPressed: busy
              ? null
              : () async {
                  Navigator.of(context).pop();
                  await ref.read(sessionProvider.notifier).logout();
                },
          child: const Text('Sign out'),
        ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: busy ? null : () => go(_Step.confirm),
        child: const Text('Back'),
      ),
    ];
  }
}

/// Shown after the member deleted their account: when it ends, and how to keep it.
class DeletionScheduledScreen extends ConsumerWidget {
  const DeletionScheduledScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = ChatTokens.of(context);
    final due = ref.watch(deletionScheduledProvider);
    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: BrandMark(size: 36),
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      'Your account is scheduled for deletion',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(color: tokens.text),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    due == null
                        ? 'It will be deleted in 30 days. You’re signed out now.'
                        : 'It will be deleted on ${deletionDate(due)}. You’re signed out now.',
                    key: const Key('delete-done-date'),
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.5,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Changed your mind? Sign in before then and tap “Keep my account”.',
                    style: TextStyle(height: 1.5, color: tokens.textSecondary),
                  ),
                  const SizedBox(height: 26),
                  FilledButton(
                    key: const Key('delete-done'),
                    onPressed: () {
                      ref.read(deletionScheduledProvider.notifier).set(null);
                      context.go('/welcome');
                    },
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where a signed-in member lands while their account is scheduled for deletion.
class PendingDeletionScreen extends ConsumerStatefulWidget {
  const PendingDeletionScreen({super.key});
  @override
  ConsumerState<PendingDeletionScreen> createState() => _PendingDeletionState();
}

class _PendingDeletionState extends ConsumerState<PendingDeletionScreen> {
  bool busy = false;
  String? error;

  Future<void> keep(PendingAccount pending) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref.read(apiProvider).cancelDeletion(pending.session);
      // Back in as an ordinary member; the router moves on from here.
      await ref.read(sessionProvider.notifier).resume(pending.session);
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => error = failure.displayMessage);
    } catch (_) {
      if (mounted) setState(() => error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> signOut(PendingAccount pending) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await ref.read(apiProvider).logout(pending.session);
    } catch (_) {
      // The credential is dropped below either way.
    }
    ref.read(pendingAccountProvider.notifier).set(null);
    await ref.read(sessionProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final pending = ref.watch(pendingAccountProvider);
    if (pending == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final due = pending.status.dueAt;
    final open = pending.status.canCancel;
    return Scaffold(
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: BrandMark(size: 36),
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      'Your account is scheduled for deletion',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(color: tokens.text),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    open
                        ? due == null
                              ? 'It will be deleted soon.'
                              : 'It will be deleted on ${deletionDate(due)}.'
                        : 'The 30 days have passed and the deletion is under way. It can no longer be undone.',
                    key: const Key('pending-date'),
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.5,
                      color: tokens.text,
                    ),
                  ),
                  if (open) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Until then you’re hidden from everyone. Keep your account and everything comes back exactly as it was.',
                      style: TextStyle(
                        height: 1.5,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 26),
                  AuthError(error),
                  if (open)
                    FilledButton(
                      key: const Key('keep-account'),
                      onPressed: busy ? null : () => keep(pending),
                      child: Text(busy ? 'One moment…' : 'Keep my account'),
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('pending-sign-out'),
                    onPressed: busy ? null : () => signOut(pending),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
