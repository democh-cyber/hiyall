import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_state.dart';
import 'api.dart';
import 'auth/auth_gateway.dart';
import 'auth/firebase_config.dart';
import 'auth/firebase_gateway.dart';
import 'chat_wipe_hook.dart';
import 'data_delivery.dart' show exportWipeProvider;
import 'deep_link.dart';
import 'error_reporting.dart';
import 'location_service.dart';
import 'pending_revoke.dart';

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
    ..onUpgradeRequired = (() =>
        ref.read(upgradeRequiredProvider.notifier).set())
    ..tokenRefresher = (() => ref.read(authGatewayProvider).refreshToken()),
);

/// True once the server refused this app version (426 UPGRADE_REQUIRED).
/// The router then shows only the "Update Hiyall" screen.
final upgradeRequiredProvider = NotifierProvider<UpgradeRequired, bool>(
  UpgradeRequired.new,
);

class UpgradeRequired extends Notifier<bool> {
  @override
  bool build() => false;
  void set() => state = true;
}

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
  int _generation = 0;

  /// Bumped when signing out. A position read before then must not be sent
  /// after, or it would list the person nearby again once they've left.
  int _accountEpoch = 0;
  int get accountEpoch => _accountEpoch;
  final _locationWrites = <Future<void>>{};

  /// Work that runs whenever a session ends: sign-out (before the session is
  /// revoked, while the credential still works: push notifications clear this
  /// device's token), expiry, and account deletion. Best effort: each hook is
  /// given [signOutHookTimeout], and one that throws or hangs is logged and
  /// skipped, never allowed to keep the person signed in.
  final signOutHooks = <Future<void> Function()>[];

  /// The longest one sign-out hook may take.
  Duration signOutHookTimeout = const Duration(seconds: 5);

  /// The session that is ending, for hooks that need to know whose data to
  /// remove (the state is already empty when a session expires).
  Session? _departing;

  /// True while [logout] or [signOutProvider] runs, so the 401 that a revoked
  /// credential answers with does not start a second, "expired" sign-out.
  bool _signingOut = false;

  Future<void> _runSignOutHooks() async {
    for (final hook in signOutHooks.toList()) {
      try {
        await hook().timeout(signOutHookTimeout);
      } catch (error, stack) {
        // Logged without detail: the error type only, no message that might carry data.
        ErrorReporting.capture(
          StateError('sign-out hook failed: ${error.runtimeType}'),
          stack,
        );
      }
    }
  }

  /// Forgets everything that belonged to the account that just left: a page it
  /// was heading for, and a pending hook's view of who it was.
  void _forgetAccount() {
    ref.read(deepLinkMemoryProvider).clear();
  }

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
    // The local clean-up that must happen whenever a session ends, registered
    // here so it does not depend on any screen or provider still listening.
    signOutHooks
      ..add(chatWipeHook(ref, () => _departing))
      ..add(() => ref.read(exportWipeProvider)());
    // A sign-out that couldn't reach the server last time is sent now.
    unawaited(
      ref
          .read(revokeQueueProvider)
          .flush(ref.read(apiProvider))
          .catchError((_) {}),
    );
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
    final Profile profile;
    try {
      profile = await api.profile(Session(token, '', live: live));
    } on ApiFailure catch (error) {
      // A member in the deletion grace period is refused everything but the deletion routes: they get
      // the screen that offers to keep the account instead of being signed out.
      if (error.status == 401) {
        final pending = await pendingDeletionOf(
          api,
          Session(token, '', live: live),
        );
        if (pending != null) {
          ref.read(pendingAccountProvider.notifier).set(pending);
          return null;
        }
      }
      rethrow;
    }
    ref.read(pendingAccountProvider.notifier).set(null);
    final session = Session(token, profile.userId, live: live);
    final status = await api.onboarding(session);
    return session.copyWith(onboarded: status.completed);
  }

  /// Re-reads the provider's account, e.g. after the person verified their
  /// email, and reconnects the app to it.
  Future<void> refreshAuth() async {
    final gateway = ref.read(authGatewayProvider);
    if (!gateway.configured) return;
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

  /// The member kept their account (it was pending deletion): reconnect to the API as an ordinary one.
  Future<void> resume(Session pending) async {
    ref.read(pendingAccountProvider.notifier).set(null);
    booting = true;
    state = const AsyncLoading();
    final result = await AsyncValue.guard<Session?>(() async {
      final api = ref.read(apiProvider);
      final profile = await api.profile(pending);
      final session = Session(
        pending.token,
        profile.userId,
        live: () => pending.token,
      );
      final status = await api.onboarding(session);
      return session.copyWith(onboarded: status.completed);
    });
    booting = false;
    state = result;
  }

  /// The person finished onboarding; let them into the app.
  void markOnboarded() {
    final session = state.asData?.value;
    if (session == null || session.onboarded) return;
    state = AsyncData(session.copyWith(onboarded: true));
  }

  /// The server no longer accepts this session; drop it locally.
  void expire() {
    final session = state.asData?.value;
    if (session == null || _signingOut) return;
    _departing = session;
    ref.read(sessionExpiredProvider.notifier).set(true);
    unawaited(ref.read(authGatewayProvider).signOut());
    _forgetAccount();
    state = const AsyncData(null);
    // The credential is already dead, so server calls in hooks fail quietly;
    // the local clean-up (chat data, export files) is what this is for.
    unawaited(_runSignOutHooks().whenComplete(() => _departing = null));
  }

  /// Signs out. Always finishes on this device, even offline: if the server
  /// could not be told, the revoke is queued ([RevokeQueue]) and sent on the
  /// next launch.
  Future<void> logout() async {
    final session = state.asData?.value;
    _signingOut = true;
    _departing = session;
    try {
      await _logout(session);
    } finally {
      _signingOut = false;
      _departing = null;
    }
  }

  Future<void> _logout(Session? session) async {
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
      // This device stops getting the account's pushes while the credential still works.
      await _runSignOutHooks();
      try {
        await ref.read(apiProvider).logout(session);
      } on ApiFailure catch (error) {
        // 401: the server already ended it. Anything else: try again later.
        if (error.status != 401) {
          await ref.read(revokeQueueProvider).add(session.token);
        }
      } catch (_) {
        await ref.read(revokeQueueProvider).add(session.token);
      }
    }
    try {
      await ref.read(authGatewayProvider).signOut();
    } catch (_) {
      // The provider's local sign-out failing must not leave the app signed in.
    }
    ref.read(sessionExpiredProvider.notifier).set(false);
    ref.read(awaitingVerificationProvider.notifier).set(null);
    _forgetAccount();
    state = const AsyncData(null);
  }

  /// Signs out of the identity provider alone: after the member deleted the
  /// account (the server already ended every session), and for accounts that
  /// never got a server session (unverified email, failed start-up). The
  /// local clean-up hooks run when there was a session.
  Future<void> signOutProvider() async {
    final session = state.asData?.value;
    _signingOut = true;
    _departing = session;
    try {
      if (session != null) await _runSignOutHooks();
      await ref.read(authGatewayProvider).signOut();
    } finally {
      _signingOut = false;
      _departing = null;
    }
    ref.read(awaitingVerificationProvider.notifier).set(null);
    _forgetAccount();
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
