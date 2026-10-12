import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'auth/auth_gateway.dart';
import 'auth/firebase_config.dart';
import 'auth/firebase_gateway.dart';
import 'location_service.dart';

const anjaliId = '019a4000-0000-7000-8000-000000000001';
const nikoId = '019a4000-0000-7000-8000-000000000002';

/// Development fixture that has not finished onboarding, for trying that flow.
const samId = '019a4000-0000-7000-8000-0000000000a1';

/// The identity provider. Real Firebase when its keys were supplied to the
/// build; otherwise a stand-in whose actions say sign-in isn't set up.
final authGatewayProvider = Provider<AuthGateway>((ref) {
  if (!FirebaseConfig.isConfigured) return const UnconfiguredAuthGateway();
  final gateway = FirebaseAuthGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});

final apiProvider = Provider<ApiClient>(
  (ref) => ApiClient()
    ..onUnauthorized = (() => ref.read(sessionProvider.notifier).expire())
    ..tokenRefresher = (() => ref.read(authGatewayProvider).refreshToken()),
);

/// The device's location. Replaced by a fake in tests.
final locationServiceProvider = Provider<LocationService>(
  (ref) => const DeviceLocationService(),
);

/// A password account that has signed up but not yet confirmed its address.
/// The API refuses it until then, so the app holds it on the verify screen.
final awaitingVerificationProvider =
    NotifierProvider<AwaitingVerification, AuthUser?>(AwaitingVerification.new);

class AwaitingVerification extends Notifier<AuthUser?> {
  @override
  AuthUser? build() => null;
  void set(AuthUser? user) => state = user;
}

/// True after the server ended the session, until the next sign-in, so the
/// welcome screen can say why the person was signed out.
final sessionExpiredProvider = NotifierProvider<SessionExpired, bool>(
  SessionExpired.new,
);

class SessionExpired extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final sessionProvider =
    NotifierProvider<SessionController, AsyncValue<Session?>>(
      SessionController.new,
    );

class SessionController extends Notifier<AsyncValue<Session?>> {
  /// True from launch until the identity provider has reported who (if anyone)
  /// is signed in, and again while a provider account is being connected to
  /// the API, so the router shows a splash instead of flashing Welcome.
  bool booting = false;
  bool _devSession = false;
  int _generation = 0;

  /// Bumped when signing out. A position read before then must not be sent
  /// after, or it would list the person nearby again once they've left.
  int _accountEpoch = 0;
  int get accountEpoch => _accountEpoch;
  final _locationWrites = <Future<void>>{};

  /// Sends a position for the account of [epoch], unless it has signed out
  /// since. Sign-out waits for writes already on the wire.
  Future<void> shareLocation(int epoch, Future<void> Function() write) async {
    if (epoch != _accountEpoch) return;
    final pending = write();
    _locationWrites.add(pending);
    try {
      await pending;
    } finally {
      _locationWrites.remove(pending);
    }
  }

  @override
  AsyncValue<Session?> build() {
    final gateway = ref.watch(authGatewayProvider);
    if (!gateway.configured) return const AsyncData(null);
    booting = true;
    final subscription = gateway.userChanges().listen(
      (user) => unawaited(_onUser(user)),
      onError: (Object error, StackTrace stack) {
        booting = false;
        state = AsyncError(error, stack);
      },
    );
    ref.onDispose(subscription.cancel);
    return const AsyncLoading();
  }

  Future<void> _onUser(AuthUser? user) async {
    final gateway = ref.read(authGatewayProvider);
    final generation = ++_generation;
    final awaiting = ref.read(awaitingVerificationProvider.notifier);
    if (user == null) {
      if (_devSession) return;
      awaiting.set(null);
      booting = false;
      state = const AsyncData(null);
      return;
    }
    if (user.needsEmailVerification) {
      awaiting.set(user);
      booting = false;
      state = const AsyncData(null);
      return;
    }
    awaiting.set(null);
    // A working session stays on screen while it's re-checked; otherwise the
    // router shows the splash rather than Welcome until this settles.
    if (state.asData?.value == null) {
      booting = true;
      state = const AsyncLoading();
    }
    final result = await AsyncValue.guard(() => _establish(gateway));
    if (generation != _generation) return;
    booting = false;
    state = result;
  }

  /// Exchanges the provider's token for the API's view of the account. The
  /// first authenticated call also creates the account on the server.
  Future<Session?> _establish(AuthGateway gateway) async {
    final token = await gateway.idToken();
    String live() => gateway.cachedToken ?? token;
    final api = ref.read(apiProvider);
    final profile = await api.profile(Session(token, '', live: live));
    final session = Session(token, profile.userId, live: live);
    final status = await api.onboarding(session);
    return session.copyWith(onboarded: status.completed);
  }

  /// Re-reads the provider's account, e.g. after the person verified their
  /// email, and reconnects the app to it.
  Future<void> refreshAuth() async {
    final gateway = ref.read(authGatewayProvider);
    if (!gateway.configured || _devSession) return;
    final AuthUser? user;
    try {
      user = await gateway.reload();
    } catch (error, stack) {
      // Offline, or the account was disabled: say so where the person is
      // (splash or verify page) rather than leaving the last state up.
      if (state.asData?.value == null) {
        booting = false;
        state = AsyncError(error, stack);
      }
      rethrow;
    }
    await _onUser(user);
  }

  Future<void> login(String id) async {
    if (state.isLoading) return;
    ref.read(sessionExpiredProvider.notifier).set(false);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final api = ref.read(apiProvider);
      final session = await api.signInDevelopment(id);
      _devSession = true;
      final status = await api.onboarding(session);
      return session.copyWith(onboarded: status.completed);
    });
  }

  /// The person finished onboarding; let them into the app.
  void markOnboarded() {
    final session = state.asData?.value;
    if (session == null || session.onboarded) return;
    state = AsyncData(session.copyWith(onboarded: true));
  }

  /// The server no longer accepts this session; drop it locally.
  void expire() {
    if (state.asData?.value == null) return;
    ref.read(sessionExpiredProvider.notifier).set(true);
    _devSession = false;
    unawaited(ref.read(authGatewayProvider).signOut());
    state = const AsyncData(null);
  }

  Future<void> logout() async {
    final session = state.asData?.value;
    // Keep the credential until the server acknowledges revocation; failures are visible.
    if (session != null) {
      // No new position goes out from here on; one already sent lands first
      // so the removal below is the last word.
      _accountEpoch++;
      if (_locationWrites.isNotEmpty) {
        await Future.wait(_locationWrites.toList())
            .timeout(const Duration(seconds: 3), onTimeout: () => [])
            .catchError((_) => <void>[]);
      }
      // Stop being listed nearby; best effort, the position also expires.
      try {
        await ref.read(apiProvider).stopSharingLocation(session);
      } catch (_) {}
      try {
        await ref.read(apiProvider).logout(session);
      } on ApiFailure catch (error) {
        if (error.status != 401) rethrow;
      }
    }
    _devSession = false;
    await ref.read(authGatewayProvider).signOut();
    ref.read(sessionExpiredProvider.notifier).set(false);
    ref.read(awaitingVerificationProvider.notifier).set(null);
    state = const AsyncData(null);
  }

  /// Signs out of the identity provider alone, for accounts that never got a
  /// server session (unverified email, failed start-up).
  Future<void> signOutProvider() async {
    await ref.read(authGatewayProvider).signOut();
    ref.read(awaitingVerificationProvider.notifier).set(null);
    state = const AsyncData(null);
  }
}

Session requireSession(Ref ref) {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) throw const ApiFailure('Sign in to continue.');
  return session;
}

// Authorization/visibility failures are stable states; only transient failures retry.
Duration? apiReadRetry(int attempt, Object error) {
  if (error is ApiFailure &&
      error.status != null &&
      error.status! >= 400 &&
      error.status! < 500 &&
      error.status != 429) {
    return null;
  }
  return ProviderContainer.defaultRetry(attempt, error);
}

final profileProvider = FutureProvider<Profile>(
  (ref) => ref.watch(apiProvider).profile(requireSession(ref)),
  retry: apiReadRetry,
);
final privacyProvider = FutureProvider<Privacy>(
  (ref) => ref.watch(apiProvider).privacy(requireSession(ref)),
  retry: apiReadRetry,
);
final otherProfileProvider = FutureProvider.autoDispose.family<Profile, String>(
  (ref, id) => ref.watch(apiProvider).otherProfile(requireSession(ref), id),
  retry: apiReadRetry,
);
