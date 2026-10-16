import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/auth/auth_gateway.dart';
import '../../core/auth/firebase_config.dart';
import '../../core/error_reporting.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../legal_screens.dart';

/// True when this build can sign someone in with email or a social provider.
bool signInAvailable(WidgetRef ref) =>
    ref.watch(authGatewayProvider).configured;

/// Shared frame for the sign-in pages: brand, optional back arrow, title and a
/// centred column that stays readable on desktop widths.
class AuthScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool back;
  const AuthScaffold({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.back = true,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              narrow ? 22 : 32,
              12,
              narrow ? 22 : 32,
              32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (back)
                        IconButton(
                          tooltip: 'Back',
                          onPressed: () => context.canPop()
                              ? context.pop()
                              : context.go('/welcome'),
                          icon: const Icon(Icons.arrow_back_rounded),
                        )
                      else
                        const SizedBox(height: 48),
                      const Spacer(),
                      const BrandMark(size: 36),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        height: 1.6,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A short, tinted message above a form.
class AuthNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const AuthNotice(
    this.text, {
    super.key,
    this.icon = Icons.info_outline,
    this.color = VibeColors.lilac,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: VibeColors.ink, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: VibeColors.ink, height: 1.5),
          ),
        ),
      ],
    ),
  );
}

class SessionEndedNotice extends ConsumerWidget {
  const SessionEndedNotice({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sessionExpiredProvider)) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(bottom: 20),
      child: AuthNotice(
        key: Key('session-ended'),
        'Your session ended. Sign in again to pick up where you left off.',
        icon: Icons.lock_clock_outlined,
        color: VibeColors.peach,
      ),
    );
  }
}

/// Shown on every auth page when the build has no Firebase keys.
class NotConfiguredNotice extends ConsumerWidget {
  const NotConfiguredNotice({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (signInAvailable(ref)) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(bottom: 20),
      child: AuthNotice(
        key: Key('not-configured'),
        'Sign-in is not set up for this build yet. You can look around, but you can’t log in or create an account.',
        icon: Icons.build_circle_outlined,
        color: VibeColors.peach,
      ),
    );
  }
}

class AuthError extends StatelessWidget {
  final String? message;
  const AuthError(this.message, {super.key});
  @override
  Widget build(BuildContext context) => message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Semantics(
            liveRegion: true,
            child: Text(
              message!,
              key: const Key('auth-error'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                height: 1.5,
              ),
            ),
          ),
        );
}

class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final bool enabled, creating;
  final TextInputAction action;
  final VoidCallback? onSubmitted;
  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.enabled = true,
    this.creating = false,
    this.action = TextInputAction.done,
    this.onSubmitted,
  });
  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool hidden = true;
  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    enabled: widget.enabled,
    obscureText: hidden,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: widget.action,
    autofillHints: [
      widget.creating ? AutofillHints.newPassword : AutofillHints.password,
    ],
    onFieldSubmitted: (_) => widget.onSubmitted?.call(),
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        tooltip: hidden ? 'Show password' : 'Hide password',
        onPressed: () => setState(() => hidden = !hidden),
        icon: Icon(
          hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
      ),
    ),
    validator: (value) {
      final text = value ?? '';
      if (text.isEmpty) return 'Enter your password.';
      if (widget.creating && text.length < 8) {
        return 'Use at least 8 characters.';
      }
      return null;
    },
  );
}

String? validateEmail(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return 'Enter your email address.';
  if (!emailPattern.hasMatch(text)) return 'Enter a valid email address.';
  return null;
}

/// "or" divider followed by the social providers.
class SocialSignIn extends StatelessWidget {
  final bool enabled;
  final VoidCallback onGoogle, onFacebook;

  /// Sign in with Apple. The button shows only when this is set and [showApple]
  /// allows it, so a screen that does not offer Apple simply leaves it null.
  final VoidCallback? onApple;

  /// Facebook is hidden unless the build turns it on (see [AuthProviders]).
  final bool showFacebook;

  /// Defaults to the platform rules in [AuthProviders.appleAvailable]; tests
  /// inject a value.
  final bool? showApple;
  const SocialSignIn({
    super.key,
    required this.enabled,
    required this.onGoogle,
    required this.onFacebook,
    this.onApple,
    this.showFacebook = AuthProviders.facebook,
    this.showApple,
  });
  @override
  Widget build(BuildContext context) {
    final apple =
        onApple != null && (showApple ?? AuthProviders.appleAvailable());
    return _build(context, apple);
  }

  Widget _build(BuildContext context, bool apple) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 22),
      Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              'or',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
      const SizedBox(height: 22),
      if (apple) ...[
        AppleButton(enabled: enabled, onPressed: onApple!),
        const SizedBox(height: 12),
      ],
      OutlinedButton.icon(
        key: const Key('google-button'),
        onPressed: enabled ? onGoogle : null,
        icon: const GoogleMark(size: 20),
        label: const Text('Continue with Google'),
      ),
      if (showFacebook) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('facebook-button'),
          onPressed: enabled ? onFacebook : null,
          icon: const Icon(Icons.facebook, color: Color(0xff1877f2), size: 22),
          label: const Text('Continue with Facebook'),
        ),
      ],
    ],
  );
}

/// "Continue with Apple" in Apple's own button style: black with white type, and
/// the reverse in the dark theme, so it stays AA on either background.
class AppleButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onPressed;
  const AppleButton({
    super.key,
    required this.enabled,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? Colors.white : Colors.black;
    final foreground = dark ? Colors.black : Colors.white;
    return FilledButton.icon(
      key: const Key('apple-button'),
      onPressed: enabled ? onPressed : null,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: background.withValues(alpha: .4),
        disabledForegroundColor: foreground.withValues(alpha: .8),
      ),
      icon: const Icon(Icons.apple, size: 24),
      label: const Text('Continue with Apple'),
    );
  }
}

/// The four-colour Google "G".
class GoogleMark extends StatelessWidget {
  final double size;
  const GoogleMark({super.key, this.size = 20});
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _GooglePainter()),
  );
}

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * .2;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const red = Color(0xffea4335), yellow = Color(0xfffbbc05);
    const green = Color(0xff34a853), blue = Color(0xff4285f4);
    canvas.drawArc(rect, -math.pi * .22, -math.pi * .56, false, arc(red));
    canvas.drawArc(rect, -math.pi * .78, -math.pi * .5, false, arc(yellow));
    canvas.drawArc(rect, math.pi * .72, math.pi * .5, false, arc(green));
    canvas.drawArc(rect, math.pi * .22, math.pi * .5, false, arc(blue));
    canvas.drawLine(
      Offset(size.width * .52, size.height * .5),
      Offset(size.width - stroke / 2, size.height * .5),
      arc(blue),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Runs an auth action with a busy flag and turns failures into one message.
mixin AuthActions<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool busy = false;
  String? error;

  Future<bool> perform(Future<void> Function() action) async {
    if (busy) return false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      return true;
    } on AuthFailure catch (failure) {
      if (!failure.cancelled && mounted) {
        setState(() => error = failure.message);
      }
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => error = failure.displayMessage);
    } catch (error, stack) {
      // Anything else (a provider or network exception the gateway didn't map) must
      // still reach the person: swallowing it leaves a button that does nothing.
      // Reported (scrubbed) and, in a debug build only, printed by ErrorReporting itself: no console
      // line in a release build, where the text of a provider error can carry an address.
      ErrorReporting.capture(error, stack);
      if (mounted) {
        setState(
          () => this.error =
              'Something went wrong. Try again. (${error.runtimeType})',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return false;
  }
}

/// Who the app is for, with the Terms, Privacy Policy, Community Guidelines and
/// Children and Teens pages one tap away (they open inside the app).
class LegalLine extends StatelessWidget {
  const LegalLine({super.key});
  @override
  Widget build(BuildContext context) => const LegalFooter();
}
