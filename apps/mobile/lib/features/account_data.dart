import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;

import '../app.dart' show routerProvider;
import '../core/account_state.dart';
import '../core/api.dart';
import '../core/auth/auth_gateway.dart';
import '../core/data_delivery.dart';
import '../core/error_reporting.dart';
import '../core/state.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart';
import 'auth/auth_widgets.dart' show AuthError, PasswordField;
import 'help_safety.dart' show HelpContacts, writeTo;

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
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // Coming back to the app after a share sheet (or a crash during one):
    // any export file still on the phone is removed. A file being shared right
    // now is left alone (see wipeExportFiles).
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(ref.read(exportWipeProvider)()),
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

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
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
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

enum _Step { explain, confirm, reauth, appleNoCode }

/// Apple's own page on removing an app's access to the Apple ID ("Stop using Apple ID"). VERIFY before
/// release that this page still says that (owner check; the app only opens it).
const appleStopUsingUrl = 'https://support.apple.com/en-us/102571';

/// Where a member removes Hiyall's access to their Apple ID themselves.
const appleStopUsingSteps =
    'Settings > Apple ID > Sign in with Apple > Hiyall > Stop using Apple ID';

/// Opens [appleStopUsingUrl]. Replaced in tests, which have no browser.
@visibleForTesting
Future<bool> Function(Uri uri) appleHelpLauncher = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// A button that opens Apple's page on removing an app's access.
class AppleStopUsingButton extends StatelessWidget {
  const AppleStopUsingButton({super.key});
  @override
  Widget build(BuildContext context) => OutlinedButton(
    key: const Key('apple-stop-using-help'),
    onPressed: () async {
      var opened = false;
      try {
        opened = await appleHelpLauncher(Uri.parse(appleStopUsingUrl));
      } catch (_) {}
      if (!opened && context.mounted) {
        showMessage(
          context,
          'Couldn’t open the page. Search for “Stop using Apple ID” on support.apple.com.',
        );
      }
    },
    child: const Text('How to do it in Apple settings'),
  );
}

/// How many times Apple may come back without the code before the app stops asking.
const appleCodeAttempts = 2;

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

  /// The one-time Apple code from the last Apple re-sign-in; spent by the request, so it is cleared after.
  String? appleCode;

  /// The server answered APPLE_CODE_REQUIRED: it knows an Apple identity for this account, so Apple's
  /// sign-in is asked for whatever the account's main sign-in method is.
  bool serverWantsApple = false;

  /// Times Apple (or the server) reported that no authorization code arrived, kept per user for the
  /// life of the app so leaving this screen and coming back does not start the count again.
  int get appleMisses =>
      ref.read(appleDeletionMissesProvider.notifier).of(session.userId);

  /// Apple's code is needed: the account lists Apple as a provider (also next to Google, Facebook or a
  /// password) or the server said so.
  bool get needsApple =>
      serverWantsApple || ref.read(reauthenticatorProvider).linksApple;

  /// Apple gave no code: show why, once, instead of asking again and again.
  /// Logged with no personal data (counts only).
  void appleMissed(String where) {
    final misses = ref
        .read(appleDeletionMissesProvider.notifier)
        .add(session.userId);
    ErrorReporting.capture(
      StateError(
        'Apple account deletion: no authorization code ($where, miss $misses)',
      ),
      StackTrace.current,
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      appleCode = null;
      error = null;
      step = _Step.appleNoCode;
    });
  }

  Future<void> contactSupport() async {
    if (!HelpContacts.usable(HelpContacts.support)) {
      setState(
        () => error = 'Contact details are being set up. Try again from Help & Safety in Settings.',
      );
      return;
    }
    await writeTo(
      context,
      HelpContacts.support,
      'Delete my account (Apple sign-in)',
    );
  }

  /// Schedules the deletion. [codeUnavailable] is the member's choice, after Apple twice gave no
  /// code, to go on without it: the server then cannot disconnect Hiyall from the Apple ID, and the
  /// member removes the access themselves in Apple ID settings (the response says so).
  Future<void> schedule({bool codeUnavailable = false}) async {
    if (busy) return;
    // An account with an Apple identity always signs in with Apple again first, whatever else it signs in
    // with: that gives the one-time code the server trades for Apple's token and revokes (App Store
    // guideline 5.1.1(v)).
    final reauth = ref.read(reauthenticatorProvider);
    appleCode ??= reauth.takeAppleAuthorizationCode();
    if (needsApple && appleCode == null && !codeUnavailable) {
      // Apple already came back empty twice: no more prompts, only the way out.
      go(appleMisses >= appleCodeAttempts ? _Step.appleNoCode : _Step.reauth);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final code = appleCode;
    appleCode = null;
    try {
      final status = await ref
          .read(apiProvider)
          .scheduleDeletion(
            session,
            typed,
            appleAuthorizationCode: code,
            appleCodeUnavailable: codeUnavailable && code == null,
          );
      // Every session ended on the server; leave this one too, quietly, and say when it ends.
      ref.read(deletionScheduledProvider.notifier).set(status.dueAt);
      ref.read(deletionAppleActionProvider.notifier).set(status.appleAction);
      ref.read(appleDeletionMissesProvider.notifier).clear(session.userId);
      final router = ref.read(routerProvider);
      await ref.read(sessionProvider.notifier).signOutProvider();
      router.go('/account-deleted');
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      if (failure.code == 'REAUTH_REQUIRED') {
        go(_Step.reauth);
      } else if (failure.code == 'APPLE_CODE_REQUIRED' && !codeUnavailable) {
        // The server needs Apple's one-time code.
        serverWantsApple = true;
        if (code == null) {
          // None was sent because this account was not known to need one (a Google or password
          // account with an Apple identity the app cannot see): that is no miss. Ask for Apple's
          // sign-in, or, when Apple already came back empty twice, offer the way out.
          go(
            appleMisses >= appleCodeAttempts ? _Step.appleNoCode : _Step.reauth,
          );
        } else {
          // A code was sent and the server still refused it (stale or not Apple's): a miss.
          appleMissed('server');
        }
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
          .reauthenticate(password: password.text, withApple: needsApple);
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
    final reauth = ref.read(reauthenticatorProvider);
    if (needsApple) {
      appleCode = reauth.takeAppleAuthorizationCode();
      if (appleCode == null) {
        appleMissed('reauth');
        return;
      }
    }
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
      _Step.appleNoCode => 'Apple didn’t confirm',
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
                        _Step.appleNoCode => _appleNoCode(tokens),
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
      'They’re end-to-end encrypted and live only on your devices, so we can’t read or restore them. The conversations are removed from our servers; the copy on this phone is erased when you sign out or delete your account. If you remove the app without signing out, Android erases it with the app; on iPhone it is erased the next time you open Hiyall after reinstalling.',
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
          foregroundColor: tokens.onError,
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

  List<Widget> _appleNoCode(ChatTokens tokens) {
    final giveUp = appleMisses >= appleCodeAttempts;
    return [
      Text(
        giveUp
            ? 'Apple twice signed you in without sending back the confirmation Hiyall needs to disconnect from your Apple ID. You can still delete your account now, but Hiyall cannot remove its own access to your Apple ID: you do that yourself afterwards in $appleStopUsingSteps. Until you do, Hiyall stays in the list of apps using your Apple ID. Nothing has been deleted yet.'
            : 'Apple signed you in but didn’t send back the confirmation we need to finish deleting your account and disconnect it from Apple. Nothing has been deleted.',
        key: const Key('delete-apple-explain'),
        style: TextStyle(height: 1.5, color: tokens.textSecondary),
      ),
      const SizedBox(height: 18),
      AuthError(error),
      if (!giveUp) ...[
        FilledButton(
          key: const Key('delete-apple-retry'),
          onPressed: busy ? null : confirmItsYou,
          child: Text(busy ? 'Confirming…' : 'Try Apple again'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('delete-apple-support'),
          onPressed: busy ? null : contactSupport,
          child: const Text('Contact support'),
        ),
      ] else ...[
        FilledButton(
          key: const Key('delete-apple-continue'),
          style: FilledButton.styleFrom(
            backgroundColor: tokens.error,
            foregroundColor: tokens.onError,
          ),
          onPressed: busy ? null : () => schedule(codeUnavailable: true),
          child: Text(busy ? 'Deleting…' : 'Delete my account anyway'),
        ),
        const SizedBox(height: 8),
        const AppleStopUsingButton(),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('delete-apple-support'),
          onPressed: busy ? null : contactSupport,
          child: const Text('Contact support'),
        ),
      ],
      const SizedBox(height: 8),
      TextButton(
        onPressed: busy ? null : () => go(_Step.confirm),
        child: const Text('Back'),
      ),
    ];
  }

  List<Widget> _reauth(ChatTokens tokens) {
    // An account with an Apple identity is always asked for Apple, even when it is mainly a Google,
    // Facebook or password account.
    final method = needsApple
        ? AuthMethod.apple
        : ref.read(reauthenticatorProvider).method;
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
    final appleAction = ref.watch(deletionAppleActionProvider);
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
                  if (appleAction == appleActionRemoveInSettings) ...[
                    const SizedBox(height: 18),
                    Text(
                      'One thing is left for you to do. Apple did not confirm the disconnection, so Hiyall cannot remove its own access to your Apple ID. Remove it yourself in $appleStopUsingSteps.',
                      key: const Key('delete-done-apple'),
                      style: TextStyle(height: 1.5, color: tokens.text),
                    ),
                    const SizedBox(height: 12),
                    const AppleStopUsingButton(),
                  ],
                  const SizedBox(height: 26),
                  FilledButton(
                    key: const Key('delete-done'),
                    onPressed: () {
                      ref.read(deletionScheduledProvider.notifier).set(null);
                      ref.read(deletionAppleActionProvider.notifier).set(null);
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
