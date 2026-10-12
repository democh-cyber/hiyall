import 'dart:async';

/// The provider that vouched for an account. Matches Firebase's
/// `sign_in_provider` claim so the API and the app agree on the vocabulary.
enum AuthMethod { password, google, facebook, other }

class AuthUser {
  final String uid;
  final String? email, displayName, photoUrl;
  final bool emailVerified;
  final AuthMethod method;
  const AuthUser({
    required this.uid,
    required this.method,
    this.email,
    this.displayName,
    this.photoUrl,
    this.emailVerified = false,
  });

  /// Password accounts must prove they own the address before the API accepts
  /// them. Social providers have already verified it.
  bool get needsEmailVerification =>
      method == AuthMethod.password && !emailVerified;
}

/// A sign-in problem with copy that is safe to show as-is.
class AuthFailure implements Exception {
  final String message;
  final String code;

  /// True when the person simply closed the sign-in sheet; show nothing.
  final bool cancelled;
  const AuthFailure(
    this.message, {
    this.code = 'unknown',
    this.cancelled = false,
  });
  @override
  String toString() => message;
}

/// Everything the app needs from an identity provider. The Firebase adapter is
/// the production implementation; tests supply a fake.
abstract class AuthGateway {
  /// False until the provider's keys are supplied to this build.
  bool get configured;

  /// Emits the signed-in account, or null, when the account or its
  /// verification state changes. Not on every token refresh.
  Stream<AuthUser?> userChanges();
  AuthUser? get currentUser;

  Future<AuthUser> signUpWithEmail(String email, String password);
  Future<AuthUser> signInWithEmail(String email, String password);
  Future<AuthUser> signInWithGoogle();
  Future<AuthUser> signInWithFacebook();
  Future<void> sendEmailVerification();

  /// Re-reads the account from the provider (e.g. after the person tapped the
  /// verification link) and returns it.
  Future<AuthUser?> reload();
  Future<void> sendPasswordReset(String email);
  Future<void> signOut();

  /// The current ID token, refreshed when it is close to expiry.
  Future<String> idToken();

  /// Forces a new ID token; null when nobody is signed in.
  Future<String?> refreshToken();

  /// The latest token already in memory, for callers that cannot await.
  String? get cachedToken;
}

/// Used until Firebase keys are supplied. Every action explains why it cannot
/// run instead of pretending to work.
class UnconfiguredAuthGateway implements AuthGateway {
  const UnconfiguredAuthGateway();
  static const _failure = AuthFailure(
    'Sign-in is not set up for this build yet.',
    code: 'not-configured',
  );
  @override
  bool get configured => false;
  @override
  Stream<AuthUser?> userChanges() => const Stream.empty();
  @override
  AuthUser? get currentUser => null;
  @override
  String? get cachedToken => null;
  @override
  Future<AuthUser> signUpWithEmail(String email, String password) =>
      Future.error(_failure);
  @override
  Future<AuthUser> signInWithEmail(String email, String password) =>
      Future.error(_failure);
  @override
  Future<AuthUser> signInWithGoogle() => Future.error(_failure);
  @override
  Future<AuthUser> signInWithFacebook() => Future.error(_failure);
  @override
  Future<void> sendEmailVerification() => Future.error(_failure);
  @override
  Future<AuthUser?> reload() async => null;
  @override
  Future<void> sendPasswordReset(String email) => Future.error(_failure);
  @override
  Future<void> signOut() async {}
  @override
  Future<String> idToken() => Future.error(_failure);
  @override
  Future<String?> refreshToken() async => null;
}

final emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
