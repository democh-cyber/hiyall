import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/auth/auth_gateway.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import 'auth_widgets.dart';

/// Shown while the app restores a sign-in, or when it could not reach the
/// service to finish one.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final failed = session.hasError && !session.isLoading;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: BrandMark(size: 64)),
                  const SizedBox(height: 28),
                  if (failed) ...[
                    Text(
                      'Couldn’t reach Hiyall',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      switch (session.error) {
                        ApiFailure(:final message) => message,
                        AuthFailure(:final message) => message,
                        _ => 'Check your connection and try again.',
                      },
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        height: 1.6,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('retry-session'),
                      // A failure lands in the session state shown above.
                      onPressed: () => ref
                          .read(sessionProvider.notifier)
                          .refreshAuth()
                          .catchError((_) {}),
                      child: const Text('Try again'),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () =>
                          ref.read(sessionProvider.notifier).signOutProvider(),
                      child: const Text('Use a different account'),
                    ),
                  ] else
                    const Center(
                      child: SizedBox.square(
                        dimension: 26,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
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

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final scheme = Theme.of(context).colorScheme;
    Widget actions({required bool compact}) {
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SessionEndedNotice(),
          const NotConfiguredNotice(),
          if (!compact) ...[
            const VibeTag('YOUR NEXT CHAPTER', color: VibeColors.lilac),
            const SizedBox(height: 24),
            Text(
              'Come as you are.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Your people are out there. Your space starts here.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.7),
            ),
            const SizedBox(height: 28),
          ],
          FilledButton(
            key: const Key('create-account'),
            onPressed: () => context.go('/signup'),
            child: const Text('Create account'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('log-in'),
            onPressed: () => context.go('/login'),
            child: const Text('Log in'),
          ),
          if (devLoginEnabled) ...[
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'Development accounts',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Local fixtures, available only in debug builds.',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            for (final (id, label) in const [
              (anjaliId, 'Continue as Anjali'),
              (nikoId, 'Continue as Niko'),
              (samId, 'Continue as Sam (new member)'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: OutlinedButton(
                  onPressed: session.isLoading
                      ? null
                      : () => ref.read(sessionProvider.notifier).login(id),
                  child: Text(session.isLoading ? 'Connecting…' : label),
                ),
              ),
            if (session.hasError)
              Text(
                session.error.toString(),
                style: TextStyle(color: scheme.error),
              ),
          ],
        ],
      );
      return compact
          ? content
          : VibePanel(padding: const EdgeInsets.all(30), child: content);
    }

    Widget story({required bool art}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            BrandMark(size: 44),
            SizedBox(width: 12),
            Flexible(
              child: Text(
                'hiyall',
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.8,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: MediaQuery.sizeOf(context).width < 600 ? 28 : 44),
        const VibeTag('A DIFFERENT KIND OF SOCIAL', icon: Icons.auto_awesome),
        const SizedBox(height: 22),
        Text(
          'Your people.\nYour plot.\nYour kind of weird.',
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: MediaQuery.sizeOf(context).width < 600 ? 46 : 62,
            height: 1.02,
            fontWeight: FontWeight.w700,
            letterSpacing: -2.8,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Less performing. More connecting.\nA little corner of the internet that feels like you.',
          style: TextStyle(
            height: 1.7,
            color: scheme.onSurfaceVariant,
            fontSize: 15,
          ),
        ),
        if (art) ...[const SizedBox(height: 28), const VibeArt(height: 250)],
      ],
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 600 ? 22 : 44,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: LayoutBuilder(
                builder: (context, box) =>
                    box.maxWidth >= 820 &&
                        MediaQuery.textScalerOf(context).scale(1) < 1.4
                    ? Row(
                        children: [
                          Expanded(flex: 6, child: story(art: true)),
                          const SizedBox(width: 64),
                          Expanded(flex: 5, child: actions(compact: false)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          story(art: false),
                          const SizedBox(height: 28),
                          actions(compact: true),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with AuthActions {
  final form = GlobalKey<FormState>();
  final email = TextEditingController(), password = TextEditingController();

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    final gateway = ref.read(authGatewayProvider);
    await perform(() async {
      ref.read(sessionExpiredProvider.notifier).set(false);
      await gateway.signInWithEmail(email.text, password.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final gateway = ref.watch(authGatewayProvider);
    final working = busy || session.isLoading;
    final enabled = gateway.configured && !working;
    final sessionError = session.hasError && !session.isLoading
        ? (session.error is ApiFailure
              ? (session.error as ApiFailure).message
              : null)
        : null;
    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Log in to pick up where you left off.',
      children: [
        const SessionEndedNotice(),
        const NotConfiguredNotice(),
        AuthError(error ?? sessionError),
        AutofillGroup(
          child: Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: email,
                  enabled: !working,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: validateEmail,
                ),
                const SizedBox(height: 14),
                PasswordField(
                  controller: password,
                  enabled: !working,
                  onSubmitted: submit,
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const Key('forgot-password'),
            onPressed: working ? null : () => context.push('/forgot-password'),
            child: const Text('Forgot password?'),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('login-submit'),
          onPressed: enabled ? submit : null,
          child: Text(working ? 'Logging in…' : 'Log in'),
        ),
        SocialSignIn(
          enabled: enabled,
          onGoogle: () => perform(gateway.signInWithGoogle),
          onFacebook: () => perform(gateway.signInWithFacebook),
        ),
        const SizedBox(height: 26),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('New to Hiyall?'),
            TextButton(
              onPressed: working ? null : () => context.go('/signup'),
              child: const Text('Create account'),
            ),
          ],
        ),
      ],
    );
  }
}

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});
  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> with AuthActions {
  final form = GlobalKey<FormState>();
  final email = TextEditingController(), password = TextEditingController();

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    final gateway = ref.read(authGatewayProvider);
    await perform(() async {
      ref.read(sessionExpiredProvider.notifier).set(false);
      await gateway.signUpWithEmail(email.text, password.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final gateway = ref.watch(authGatewayProvider);
    final working = busy || session.isLoading;
    final enabled = gateway.configured && !working;
    return AuthScaffold(
      title: 'Create your account',
      subtitle: 'It takes a minute. You’ll set up your profile next.',
      children: [
        const NotConfiguredNotice(),
        AuthError(error),
        AutofillGroup(
          child: Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: email,
                  enabled: !working,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: validateEmail,
                ),
                const SizedBox(height: 14),
                PasswordField(
                  controller: password,
                  enabled: !working,
                  creating: true,
                  onSubmitted: submit,
                ),
                const SizedBox(height: 8),
                Text(
                  'At least 8 characters.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        FilledButton(
          key: const Key('signup-submit'),
          onPressed: enabled ? submit : null,
          child: Text(working ? 'Creating account…' : 'Create account'),
        ),
        SocialSignIn(
          enabled: enabled,
          onGoogle: () => perform(gateway.signInWithGoogle),
          onFacebook: () => perform(gateway.signInWithFacebook),
        ),
        const SizedBox(height: 22),
        const LegalLine(),
        const SizedBox(height: 18),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Already have an account?'),
            TextButton(
              onPressed: working ? null : () => context.go('/login'),
              child: const Text('Log in'),
            ),
          ],
        ),
      ],
    );
  }
}

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordState();
}

class _ForgotPasswordState extends ConsumerState<ForgotPasswordScreen>
    with AuthActions {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  bool sent = false;

  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    final gateway = ref.read(authGatewayProvider);
    final ok = await perform(() => gateway.sendPasswordReset(email.text));
    if (ok && mounted) setState(() => sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(authGatewayProvider).configured;
    if (sent) {
      return AuthScaffold(
        title: 'Check your inbox',
        subtitle:
            'If an account exists for ${email.text.trim()}, we’ve sent a link to reset your password.',
        children: [
          FilledButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/login'),
            child: const Text('Back to log in'),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => setState(() => sent = false),
            child: const Text('Use a different email'),
          ),
        ],
      );
    }
    return AuthScaffold(
      title: 'Reset your password',
      subtitle:
          'Enter your email and we’ll send you a link to choose a new one.',
      children: [
        const NotConfiguredNotice(),
        AuthError(error),
        Form(
          key: form,
          child: TextFormField(
            controller: email,
            enabled: !busy,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            onFieldSubmitted: (_) => submit(),
            decoration: const InputDecoration(labelText: 'Email'),
            validator: validateEmail,
          ),
        ),
        const SizedBox(height: 22),
        FilledButton(
          key: const Key('reset-submit'),
          onPressed: configured && !busy ? submit : null,
          child: Text(busy ? 'Sending…' : 'Send reset link'),
        ),
      ],
    );
  }
}

/// Password sign-ups must prove they own the address before the API accepts
/// them. This page waits for that, checking on its own every few seconds.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key});
  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailState();
}

class _VerifyEmailState extends ConsumerState<VerifyEmailScreen>
    with AuthActions {
  static const cooldown = 45;
  Timer? poll, tick;
  int wait = cooldown;
  String? notice;

  @override
  void initState() {
    super.initState();
    poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!busy) {
        ref.read(sessionProvider.notifier).refreshAuth().catchError((_) {});
      }
    });
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (wait > 0 && mounted) setState(() => wait--);
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    tick?.cancel();
    super.dispose();
  }

  Future<void> check() async {
    setState(() => notice = null);
    final ok = await perform(
      () => ref.read(sessionProvider.notifier).refreshAuth(),
    );
    if (ok && mounted && ref.read(awaitingVerificationProvider) != null) {
      setState(
        () => notice = 'We haven’t seen the verification yet. Open the link in the email, then try again.',
      );
    }
  }

  Future<void> resend() async {
    final ok = await perform(
      () => ref.read(authGatewayProvider).sendEmailVerification(),
    );
    if (ok && mounted) {
      setState(() {
        wait = cooldown;
        notice = 'Sent. It can take a minute to arrive; check spam too.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final address =
        ref.watch(awaitingVerificationProvider)?.email ?? 'your email';
    final session = ref.watch(sessionProvider);
    final sessionError = session.hasError && !session.isLoading
        ? (session.error is ApiFailure
              ? (session.error as ApiFailure).message
              : null)
        : null;
    return AuthScaffold(
      back: false,
      title: 'Verify your email',
      subtitle: 'We sent a link to $address. Open it, then come back here.',
      children: [
        AuthError(error ?? sessionError),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: AuthNotice(notice!, icon: Icons.mark_email_unread_outlined),
          ),
        FilledButton(
          key: const Key('verified-button'),
          onPressed: busy || session.isLoading ? null : check,
          child: Text(
            busy || session.isLoading ? 'Checking…' : 'I’ve verified my email',
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('resend-button'),
          onPressed: busy || wait > 0 ? null : resend,
          child: Text(wait > 0 ? 'Resend email in ${wait}s' : 'Resend email'),
        ),
        const SizedBox(height: 22),
        TextButton(
          key: const Key('verify-signout'),
          onPressed: () => ref.read(sessionProvider.notifier).signOutProvider(),
          child: const Text('Use a different account'),
        ),
      ],
    );
  }
}
