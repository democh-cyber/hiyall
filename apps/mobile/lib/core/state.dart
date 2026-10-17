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
import 'last_user.dart';
import 'location_service.dart';
import 'pending_revoke.dart';
import 'signout_residue.dart';

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
    ..onAppCheckRequired = (() =>
        ref.read(appCheckRequiredProvider.notifier).set(true))
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

/// True while the server refuses this app instead of the session (401 APP_CHECK_REQUIRED). The router
/// then shows "Update or verify this app"; the session, the chat data and everything else stay as they
/// are, and "Try again" clears it.
final appCheckRequiredProvider = NotifierProvider<AppCheckRequired, bool>(
  AppCheckRequired.new,
);

class AppCheckRequired extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
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

  /// The account that was signed in last, for the clean-up of a sign-out that has no session left to name
  /// it. Also kept in a small file ([LastUserStore]) so that a start-up the server refuses in a new
  /// process still finds it.
  String? _lastUserId;

  /// Bumped every time a session is installed. A departure that finishes after a new sign-in leaves what
  /// that sign-in remembered alone.
  int _sessionSerial = 0;

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

  /// Reads the file that remembers the last account into [_lastUserId], in the background from launch on.
  /// Sign-out hooks then use the in-memory value and never wait for the disk.
  Future<void> _loadRemembered() async {
    try {
      final stored = await ref.read(lastUserStoreProvider).read();
      _lastUserId ??= stored;
    } catch (_) {}
  }

  Future<void>? _remembered;

  /// Notes that [userId] holds this phone now (memory and file). When the file still named another account
  /// (a sign-out that never finished), what that account left is cleaned up too.
  Future<void> _remember(String userId) async {
    _lastUserId = userId;
    _sessionSerial++;
    try {
      final store = ref.read(lastUserStoreProvider);
      final previous = await store.read();
      if (previous != null && previous != userId) {
        await accountResidueHook(ref, () => previous)();
      }
      await store.write(userId);
    } catch (_) {
      // Best effort: the in-memory id still serves this process.
    }
  }

  /// The local clean-up of [departing] is over. Clears what names it, but only what is still its own: a
  /// sign-in that happened meanwhile ([serial] changed) keeps the id it remembered.
  void _finishDeparture(Session? departing, int serial) {
    if (identical(_departing, departing)) _departing = null;
    if (serial != _sessionSerial) return;
    _lastUserId = null;
    // The file is cleared in the background: nothing about signing out waits for the disk.
    unawaited(
      Future<void>.sync(() => ref.read(lastUserStoreProvider).clear())
          .catchError((Object _) {}),
    );
  }

  /// Ends [session] on this phone without asking the server: the state is empty at once and the clean-up
  /// hooks run for it. For a session the server (or the identity provider) ended.
  Future<void> _endSession(Session session) {
    _accountEpoch++;
    final serial = _sessionSerial;
    _departing = session;
    ref.read(sessionExpiredProvider.notifier).set(true);
    _forgetAccount();
    state = const AsyncData(null);
    // The credential is already dead, so server calls in hooks fail quietly; the local clean-up (chat
    // data, export files) is what this is for.
    return _runSignOutHooks().whenComplete(
      () => _finishDeparture(session, serial),
    );
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
      ..add(() => ref.read(exportWipeProvider)())
      ..add(accountResidueHook(ref, () => _departing?.userId ?? _lastUserId));
    _remembered = _loadRemembered();
    // Chat entries a sign-out could not erase because the keystore would not answer go now, before the
    // chat engine opens (it waits for this, see chatWipeSettled).
    unawaited(retryPendingChatWipe(ref));
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
      final live = state.asData?.value;
      if (live != null && !_signingOut) {
        // The identity provider ended the sign-in by itself (disabled or deleted account, a revoked
        // refresh token, a sign-out from elsewhere), not this app: that is a sign-out like any other, and
        // the chat data and drafts of the account go with it.
        await _endSession(live);
        return;
      }
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
    _endedByServer = false;
    final result = await AsyncValue.guard(() => _establish(gateway));
    if (generation != _generation) return;
    final established = result.asData?.value?.userId;
    if (established != null) unawaited(_remember(established));
    if (_endedByServer && result.hasError) {
      // The server refused the credential of this start-up for good: that is a sign-out too, and
      // this phone's chat data goes with it (the same clean-up as an expiry while signed in).
      // The person stays on the error screen, which offers a retry and "use a different account".
      // Whose data that is comes from the file that remembers the last account (new process).
      _departing = null;
      final serial = _sessionSerial;
      // The account of an earlier run comes from the file; its read started at launch and is long done.
      await _remembered;
      await _runSignOutHooks();
      _finishDeparture(null, serial);
      if (generation != _generation) return;
    }
    booting = false;
    state = result;
  }

  /// Set by [_establish] when the server answered 401 and the account is not in its deletion grace
  /// period (checked, not guessed: a failed check leaves it false).
  bool _endedByServer = false;

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
      // the screen that offers to keep the account instead of being signed out. Only the server's explicit
      // UNAUTHENTICATED counts: a 401 APP_CHECK_REQUIRED says the app is not trusted, nothing about the
      // member's session, and must never wipe anything.
      if (error.status == 401 && error.code == unauthenticatedCode) {
        final probe = Session(token, '', live: live);
        try {
          final status = await api.deletionStatus(probe);
          if (status.pending) {
            ref
                .read(pendingAccountProvider.notifier)
                .set(PendingAccount(probe, status));
            return null;
          }
          _endedByServer = true;
        } on ApiFailure catch (check) {
          // The same refusal for the check: the credential is dead. Any other answer (offline) proves nothing.
          _endedByServer =
              check.status == 401 && check.code == unauthenticatedCode;
        } catch (_) {
          _endedByServer = false;
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
    final resumed = result.asData?.value?.userId;
    if (resumed != null) unawaited(_remember(resumed));
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
    unawaited(
      ref.read(authGatewayProvider).signOut().catchError((Object _) {}),
    );
    unawaited(_endSession(session));
  }

  /// Signs out. Always finishes on this device, even offline: if the server
  /// could not be told, the revoke is queued ([RevokeQueue]) and sent on the
  /// next launch.
  Future<void> logout() async {
    final session = state.asData?.value;
    final serial = _sessionSerial;
    _signingOut = true;
    _departing = session;
    try {
      await _logout(session);
    } finally {
      _signingOut = false;
      _finishDeparture(session, serial);
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
    } else {
      // No session (the sign-out of a pending-deletion member, of a start-up that failed, of an account
      // whose session already ended): the local clean-up still runs, for the account this phone's
      // chat data belongs to.
      await _runSignOutHooks();
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
  /// never got a server session (unverified email, failed start-up, "use a
  /// different account"). The local clean-up hooks always run; without a
  /// session they act on the account this phone's chat data belongs to.
  Future<void> signOutProvider() async {
    final session = state.asData?.value;
    final serial = _sessionSerial;
    _signingOut = true;
    _departing = session;
    try {
      await _runSignOutHooks();
      try {
        await ref.read(authGatewayProvider).signOut();
      } catch (_) {
        // The provider's local sign-out failing must not leave the app signed in (as in [logout]).
      }
    } finally {
      _signingOut = false;
      _finishDeparture(session, serial);
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
