import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';

import 'auth_gateway.dart';

/// Firebase Authentication behind [AuthGateway]. Email/password, Google and
/// Facebook all end in a Firebase ID token that the API verifies directly.
class FirebaseAuthGateway implements AuthGateway {
  final fb.FirebaseAuth _auth;
  FirebaseAuthGateway({fb.FirebaseAuth? auth})
    : _auth = auth ?? fb.FirebaseAuth.instance {
    _tokens = _auth.idTokenChanges().listen((user) async {
      if (user == null) {
        _cached = null;
        _refresh?.cancel();
        _refresh = null;
        return;
      }
      try {
        _cached = await user.getIdToken();
      } catch (_) {
        // The next request refreshes it.
      }
      // Firebase tokens last an hour; renew well before that while the app
      // is in the foreground. A request that still finds it stale retries
      // once with a forced refresh.
      _refresh ??= Timer.periodic(const Duration(minutes: 40), (_) async {
        try {
          _cached = await _auth.currentUser?.getIdToken(true);
        } catch (_) {}
      });
    });
  }

  late final StreamSubscription<fb.User?> _tokens;
  Timer? _refresh;
  String? _cached;

  @override
  bool get configured => true;
  @override
  String? get cachedToken => _cached;

  static AuthUser? _map(fb.User? user) {
    if (user == null) return null;
    final ids = user.providerData.map((p) => p.providerId).toSet();
    final method = ids.contains('google.com')
        ? AuthMethod.google
        : ids.contains('facebook.com')
        ? AuthMethod.facebook
        : ids.contains('apple.com')
        ? AuthMethod.apple
        : ids.contains('password')
        ? AuthMethod.password
        : AuthMethod.other;
    return AuthUser(
      uid: user.uid,
      method: method,
      email: user.email,
      displayName: user.displayName,
      photoUrl: user.photoURL,
      emailVerified: user.emailVerified,
    );
  }

  @override
  AuthUser? get currentUser => _map(_auth.currentUser);

  @override
  Stream<AuthUser?> userChanges() {
    ({String uid, bool verified})? last;
    var first = true;
    return _auth.userChanges().map(_map).where((user) {
      final key = user == null
          ? null
          : (uid: user.uid, verified: user.emailVerified);
      if (!first && key == last) return false;
      first = false;
      last = key;
      return true;
    });
  }

  Future<AuthUser> _run(Future<fb.UserCredential> Function() action) async {
    try {
      final user = _map((await action()).user);
      if (user == null) {
        throw const AuthFailure('Sign-in did not finish. Try again.');
      }
      return user;
    } on fb.FirebaseAuthException catch (error) {
      throw _failure(error);
    } on fb.FirebaseException catch (error) {
      // Not an auth error (for example a misconfigured or uninitialised app).
      debugPrint(
        'Firebase error ${error.plugin}/${error.code}: ${error.message}',
      );
      throw _failureForCode(error.code);
    }
  }

  @override
  Future<AuthUser> signUpWithEmail(String email, String password) async {
    final user = await _run(
      () => _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      ),
    );
    try {
      await _auth.currentUser?.sendEmailVerification();
    } on fb.FirebaseAuthException catch (error) {
      throw _failure(error);
    }
    return user;
  }

  @override
  Future<AuthUser> signInWithEmail(String email, String password) => _run(
    () => _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    ),
  );

  Future<fb.UserCredential> _social(fb.AuthProvider provider) => kIsWeb
      ? _auth.signInWithPopup(provider)
      : _auth.signInWithProvider(provider);

  @override
  Future<AuthUser> signInWithGoogle() =>
      _run(() => _social(fb.GoogleAuthProvider()..addScope('email')));

  @override
  Future<AuthUser> signInWithFacebook() =>
      _run(() => _social(fb.FacebookAuthProvider()..addScope('email')));

  @override
  Future<AuthUser> signInWithApple() => _run(
    () => _social(
      fb.AppleAuthProvider()
        ..addScope('email')
        ..addScope('name'),
    ),
  );

  @override
  Future<void> sendEmailVerification() async {
    try {
      await _auth.currentUser?.sendEmailVerification();
    } on fb.FirebaseAuthException catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<AuthUser?> reload() async {
    try {
      await _auth.currentUser?.reload();
      // A verified address changes the claims inside the token.
      await _auth.currentUser?.getIdToken(true);
    } on fb.FirebaseAuthException catch (error) {
      throw _failure(error);
    }
    return currentUser;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on fb.FirebaseAuthException catch (error) {
      // Never reveal whether an address has an account.
      if (error.code == 'user-not-found') return;
      throw _failure(error);
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<String> idToken() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthFailure('Sign in to continue.', code: 'signed-out');
    }
    try {
      return _cached =
          await user.getIdToken() ??
          (throw const AuthFailure('Sign in to continue.'));
    } on fb.FirebaseAuthException catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<String?> refreshToken() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      return _cached = await user.getIdToken(true);
    } on fb.FirebaseAuthException {
      return null;
    }
  }

  void dispose() {
    _tokens.cancel();
    _refresh?.cancel();
  }

  /// Firebase error codes to copy that is safe to show.
  @visibleForTesting
  static AuthFailure failureFor(String code) => _failureForCode(code);
  static AuthFailure _failure(fb.FirebaseAuthException error) =>
      _failureForCode(error.code);

  static AuthFailure _failureForCode(String code) => switch (code) {
    'invalid-credential' ||
    'wrong-password' ||
    'user-not-found' ||
    'invalid-login-credentials' => const AuthFailure(
      'That email and password don’t match.',
      code: 'invalid-credential',
    ),
    'invalid-email' => const AuthFailure(
      'Enter a valid email address.',
      code: 'invalid-email',
    ),
    'email-already-in-use' => const AuthFailure(
      'An account with this email already exists. Log in instead.',
      code: 'email-already-in-use',
    ),
    'weak-password' => const AuthFailure(
      'Choose a stronger password with at least 8 characters.',
      code: 'weak-password',
    ),
    'user-disabled' => const AuthFailure(
      'This account has been disabled. Contact support if you think that is a mistake.',
      code: 'user-disabled',
    ),
    'too-many-requests' => const AuthFailure(
      'Too many attempts. Wait a few minutes and try again.',
      code: 'too-many-requests',
    ),
    'network-request-failed' => const AuthFailure(
      'Couldn’t connect. Check your connection and try again.',
      code: 'network',
    ),
    'account-exists-with-different-credential' => const AuthFailure(
      'An account already exists with this email. Log in with the method you used first.',
      code: 'account-exists',
    ),
    'operation-not-allowed' => const AuthFailure(
      'This sign-in method isn’t enabled yet.',
      code: 'operation-not-allowed',
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
    'requires-recent-login' => const AuthFailure(
      'For your security, log in again to continue.',
      code: 'requires-recent-login',
    ),
    // The raw code is short, safe to show and what support needs to diagnose it.
    _ => AuthFailure(
      'Something went wrong signing in. Try again. ($code)',
      code: code,
    ),
  };
}
