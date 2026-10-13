import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';

import 'auth_gateway.dart';

/// Proves again that the person at the keyboard owns the account, right before
/// something the server asks a recent sign-in for (deleting the account). A
/// separate interface from [AuthGateway] so existing fakes of that stay valid.
abstract class Reauthenticator {
  const Reauthenticator();

  /// How the account signs in, or null when the person cannot be asked (no
  /// identity provider: development sessions).
  AuthMethod? get method;

  /// Signs in again with the same provider and renews the ID token so its
  /// `auth_time` is new. [password] is only used for [AuthMethod.password].
  /// Throws [AuthFailure]; a closed sign-in sheet is a cancelled one.
  Future<void> reauthenticate({String? password});
}

/// Used when there is no identity provider; the server then needs no re-sign-in.
class NoReauthenticator extends Reauthenticator {
  const NoReauthenticator();
  @override
  AuthMethod? get method => null;
  @override
  Future<void> reauthenticate({String? password}) async {}
}

/// Firebase's `reauthenticateWithCredential` / `reauthenticateWithProvider`.
class FirebaseReauthenticator extends Reauthenticator {
  final fb.FirebaseAuth _auth;
  FirebaseReauthenticator({fb.FirebaseAuth? auth})
    : _auth = auth ?? fb.FirebaseAuth.instance;

  @override
  AuthMethod? get method {
    final user = _auth.currentUser;
    if (user == null) return null;
    final ids = user.providerData.map((p) => p.providerId).toSet();
    return ids.contains('google.com')
        ? AuthMethod.google
        : ids.contains('facebook.com')
        ? AuthMethod.facebook
        : ids.contains('apple.com')
        ? AuthMethod.apple
        : ids.contains('password')
        ? AuthMethod.password
        : AuthMethod.other;
  }

  @override
  Future<void> reauthenticate({String? password}) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthFailure('Sign in to continue.', code: 'signed-out');
    }
    try {
      switch (method) {
        case AuthMethod.password:
          final email = user.email;
          if (email == null || password == null || password.isEmpty) {
            throw const AuthFailure(
              'Enter your password.',
              code: 'invalid-credential',
            );
          }
          await user.reauthenticateWithCredential(
            fb.EmailAuthProvider.credential(email: email, password: password),
          );
        case AuthMethod.google:
          await _provider(user, fb.GoogleAuthProvider()..addScope('email'));
        case AuthMethod.facebook:
          await _provider(user, fb.FacebookAuthProvider()..addScope('email'));
        case AuthMethod.apple:
          await _provider(user, fb.AppleAuthProvider()..addScope('email'));
        case AuthMethod.other || null:
          throw const AuthFailure(
            'Sign out and sign in again, then try once more.',
            code: 'requires-recent-login',
          );
      }
      // The new sign-in time travels in the next ID token.
      await user.getIdToken(true);
    } on fb.FirebaseAuthException catch (error) {
      throw failureFor(error.code);
    }
  }

  Future<void> _provider(fb.User user, fb.AuthProvider provider) async {
    if (kIsWeb) {
      await user.reauthenticateWithPopup(provider);
    } else {
      await user.reauthenticateWithProvider(provider);
    }
  }

  /// Firebase error codes to copy that is safe to show.
  @visibleForTesting
  static AuthFailure failureFor(String code) => switch (code) {
    'wrong-password' ||
    'invalid-credential' ||
    'invalid-login-credentials' => const AuthFailure(
      'That password doesn’t match.',
      code: 'invalid-credential',
    ),
    'too-many-requests' => const AuthFailure(
      'Too many attempts. Wait a few minutes and try again.',
      code: 'too-many-requests',
    ),
    'network-request-failed' => const AuthFailure(
      'Couldn’t connect. Check your connection and try again.',
      code: 'network',
    ),
    'user-mismatch' => const AuthFailure(
      'Use the account you are signed in with.',
      code: 'user-mismatch',
    ),
    'popup-closed-by-user' ||
    'cancelled-popup-request' ||
    'web-context-canceled' ||
    'web-context-cancelled' ||
    'canceled' ||
    'user-cancelled' => const AuthFailure(
      '',
      code: 'cancelled',
      cancelled: true,
    ),
    _ => AuthFailure(
      'Couldn’t confirm it’s you. Try again. ($code)',
      code: code,
    ),
  };
}
