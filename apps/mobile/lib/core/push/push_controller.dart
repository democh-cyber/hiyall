import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_bindings.dart';
import '../chat/chat_engine.dart' show ChatEngine;
import '../state.dart';
import 'push_prefs.dart';
import 'push_service.dart';

/// What the app asks of the server about push: where this device's token goes
/// and the member's chat/social choices (the server enforces them).
abstract class PushBackend {
  /// The device id the chat engine registered, or null where there is no chat engine.
  Future<String?> deviceId();
  Future<void> register(String deviceId, String token);
  Future<void> clear(String deviceId);
  Future<Map<String, bool>> prefs();
  Future<Map<String, bool>> setPrefs(Map<String, bool> patch);
}

class ChatPushBackend implements PushBackend {
  final Ref ref;
  ChatPushBackend(this.ref);
  Future<ChatEngine?> _engine() => ref.read(chatEngineSourceProvider.future);

  @override
  Future<String?> deviceId() async => (await _engine())?.deviceId;
  @override
  Future<void> register(String deviceId, String token) async =>
      (await _engine())?.api.setPushToken(deviceId, 'fcm', token);
  @override
  Future<void> clear(String deviceId) async =>
      (await _engine())?.api.clearPushToken(deviceId);
  @override
  Future<Map<String, bool>> prefs() async =>
      (await _engine())?.api.notificationPrefs() ??
      {'chat': true, 'social': true};
  @override
  Future<Map<String, bool>> setPrefs(Map<String, bool> patch) async =>
      (await _engine())!.api.setNotificationPrefs(patch);
}

final pushBackendProvider = Provider<PushBackend>(ChatPushBackend.new);

/// Opens a location in the app. Replaced in tests.
final pushOpenerProvider = Provider<void Function(String)>(
  (ref) =>
      (location) => ref.read(routeOpenerProvider)(location),
);

/// The member's chat/social choices, read from the server.
final notificationPrefsProvider = FutureProvider.autoDispose<Map<String, bool>>(
  (ref) => ref.watch(pushBackendProvider).prefs(),
);

class PushState {
  final PushPermission permission;

  /// This device's token is with the server.
  final bool registered;

  /// The member switched notifications off in Settings on this device.
  final bool switchedOff;

  /// The explainer sheet should be shown (see PushHost).
  final bool explainerDue;
  const PushState({
    this.permission = PushPermission.notAsked,
    this.registered = false,
    this.switchedOff = false,
    this.explainerDue = false,
  });
  PushState copyWith({
    PushPermission? permission,
    bool? registered,
    bool? switchedOff,
    bool? explainerDue,
  }) => PushState(
    permission: permission ?? this.permission,
    registered: registered ?? this.registered,
    switchedOff: switchedOff ?? this.switchedOff,
    explainerDue: explainerDue ?? this.explainerDue,
  );

  /// Pushes are on for this device.
  bool get on =>
      permission == PushPermission.granted && !switchedOff && registered;
}

final pushControllerProvider = NotifierProvider<PushController, PushState>(
  PushController.new,
);

/// Registers this device for push, asks permission at a meaningful moment and
/// sends notification taps to the right screen. Nothing here runs unless the
/// platform service says push is supported (never on web, desktop or in tests
/// that do not install a fake).
class PushController extends Notifier<PushState> {
  String? _userId;
  bool _ready = false;
  String? _sentToken, _deviceId;
  PushTap? _pending;
  bool _asked = false, _initialChecked = false;

  PushService get _service => ref.read(pushServiceProvider);
  PushPrefsStore get _store => ref.read(pushPrefsStoreProvider);

  @override
  PushState build() {
    final who = ref.watch(
      sessionProvider.select((s) {
        final v = s.asData?.value;
        return (v?.userId, v?.onboarded ?? false);
      }),
    );
    if (who.$1 != _userId) {
      _asked = false;
      _sentToken = null;
      _deviceId = null;
    }
    _userId = who.$1;
    _ready = who.$2;
    final service = _service;
    if (!service.supported) return const PushState();
    final subs = <StreamSubscription<Object?>>[
      service.tokenRefresh.listen(_onToken),
      service.taps.listen(_open),
    ];
    ref.onDispose(() {
      for (final s in subs) {
        s.cancel();
      }
    });
    // The two moments permission is asked for: the first message sent and the first follow.
    ref.read(apiProvider).onFollowed = () => unawaited(engaged());
    final session = ref.read(sessionProvider.notifier);
    session.signOutHooks.add(beforeSignOut);
    ref.onDispose(() => session.signOutHooks.remove(beforeSignOut));
    ref.listen(chatEngineSourceProvider, (_, next) {
      next.asData?.value?.api.onSent = () => unawaited(engaged());
    }, fireImmediately: true);
    scheduleMicrotask(_start);
    return const PushState();
  }

  Future<void> _start() async {
    if (!ref.mounted) return;
    if (!_initialChecked) {
      _initialChecked = true;
      final tap = await _service.initialTap();
      if (tap != null) _open(tap);
    }
    final id = _userId;
    if (id == null || !ref.mounted) return;
    final permission = await _service.permission();
    final off = await _store.switchedOff(id);
    if (!ref.mounted || id != _userId) return;
    state = state.copyWith(permission: permission, switchedOff: off);
    if (permission == PushPermission.granted && !off) await _register();
    final pending = _pending;
    if (pending != null && _ready) {
      _pending = null;
      _open(pending);
    }
  }

  /// A tap goes to its screen once the member is signed in and past onboarding;
  /// until then (a cold start) it waits.
  void _open(PushTap tap) {
    if (_userId == null || !_ready) {
      _pending = tap;
      return;
    }
    ref.read(pushOpenerProvider)(tap.location);
  }

  void _onToken(String token) {
    if (state.permission == PushPermission.granted && !state.switchedOff) {
      unawaited(_send(token));
    }
  }

  Future<void> _register() async {
    final token = await _service.token();
    if (token != null) await _send(token);
  }

  Future<void> _send(String token) async {
    if (token == _sentToken) return;
    final backend = ref.read(pushBackendProvider);
    try {
      final id = await backend.deviceId();
      if (id == null || !ref.mounted) return;
      await backend.register(id, token);
      _sentToken = token;
      _deviceId = id;
      if (ref.mounted) state = state.copyWith(registered: true);
    } catch (_) {
      // Offline or signed out meanwhile; the next launch or token refresh retries.
    }
  }

  /// The member just did something that shows they care about replies (sent a
  /// message, followed someone). Registers when permission is already there,
  /// and otherwise asks for the explainer sheet, unless they said "Not now"
  /// within the last [pushAskEvery] or the system already refused.
  Future<void> engaged() async {
    final id = _userId;
    if (id == null || !_service.supported) return;
    final permission = await _service.permission();
    if (!ref.mounted) return;
    state = state.copyWith(permission: permission);
    if (permission == PushPermission.granted) {
      if (!await _store.switchedOff(id)) await _register();
      return;
    }
    if (permission == PushPermission.denied || _asked) return;
    final last = await _store.lastNotNow(id);
    if (!ref.mounted) return;
    if (last != null &&
        ref.read(pushClockProvider)().difference(last) < pushAskEvery) {
      return;
    }
    _asked = true;
    state = state.copyWith(explainerDue: true);
  }

  /// "Turn on" in the explainer: the system dialog, then registration.
  Future<void> accept() async {
    final id = _userId;
    state = state.copyWith(explainerDue: false);
    final permission = await _service.requestPermission();
    if (!ref.mounted) return;
    state = state.copyWith(permission: permission);
    if (permission == PushPermission.granted && id != null) {
      await _store.saveSwitchedOff(id, false);
      state = state.copyWith(switchedOff: false);
      await _register();
    }
  }

  /// "Not now": remembered, so the explainer stays away for [pushAskEvery].
  Future<void> notNow() async {
    final id = _userId;
    state = state.copyWith(explainerDue: false);
    if (id != null) await _store.saveNotNow(id, ref.read(pushClockProvider)());
  }

  /// Settings switch on, for a member whose system permission is already granted.
  Future<void> enable() async {
    final id = _userId;
    if (id == null) return;
    await _store.saveSwitchedOff(id, false);
    state = state.copyWith(switchedOff: false);
    await _register();
  }

  /// Settings switch off: the server forgets this device's token and so does FCM.
  Future<void> disable() async {
    final id = _userId;
    if (id == null) return;
    await _store.saveSwitchedOff(id, true);
    state = state.copyWith(switchedOff: true);
    await _forget();
  }

  /// Called before sign-out revokes the session, while the credential still
  /// works: this device stops receiving the account's pushes. Best effort, bounded.
  Future<void> beforeSignOut() async {
    if (!_service.supported) return;
    await _forget();
  }

  static const _forgetStepLimit = Duration(seconds: 2);

  Future<void> _forget() async {
    final backend = ref.read(pushBackendProvider);
    try {
      // Every step is bounded: sign-out must not wait on a slow keystore or
      // network (the sign-out hook has its own, longer limit as well).
      final id =
          _deviceId ?? await backend.deviceId().timeout(_forgetStepLimit);
      if (id != null) {
        await backend.clear(id).timeout(_forgetStepLimit);
      }
    } catch (_) {}
    try {
      await _service.deleteToken().timeout(_forgetStepLimit);
    } catch (_) {}
    _sentToken = null;
    if (ref.mounted) state = state.copyWith(registered: false);
  }
}
