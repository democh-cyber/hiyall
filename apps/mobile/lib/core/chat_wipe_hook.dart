import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'app_bindings.dart';
import 'app_info.dart';
import 'chat/chat_api.dart';
import 'chat/chat_local_data.dart';
import 'chat/chat_store.dart' show ChatStore;

/// Where the chat data folders live. Replaced by a temp folder in tests.
final chatWipeRootProvider = Provider<Future<Directory> Function()>(
  (ref) => getApplicationSupportDirectory,
);

/// Removes this phone's chat device on the server, with the departing
/// account's credential. Replaced by a fake in tests.
typedef ChatDeviceRevoker = Future<void> Function(Session s, String deviceId);

final chatDeviceRevokerProvider = Provider<ChatDeviceRevoker>(
  (ref) =>
      (session, deviceId) => ChatApi(
        apiBaseUrl,
        session.token,
        clientVersion: AppInfo.version,
        clientPlatform: clientPlatform,
      ).revokeDevice(deviceId),
);

/// How long the server is given to remove the chat device before the local
/// wipe goes on without it (the id is then remembered and retried next launch).
const chatRevokeTimeout = Duration(seconds: 3);

/// The sign-out wipes that have started and not finished. A hook that ran out
/// of its time (see `SessionController.signOutHookTimeout`) is not cancelled, so
/// anything that opens chat data again waits for these ([chatWipeSettled]).
final _wipesInFlight = <Future<void>>{};

/// Completes when every chat wipe started by [chatWipeHook] has finished (it
/// never throws). The chat engine awaits this before it opens for an account,
/// so a slow wipe of the same account cannot delete keys or files the new
/// engine has just written. A wipe that hangs is waited for at most [limit].
Future<void> chatWipeSettled({
  Duration limit = const Duration(seconds: 30),
}) async {
  while (_wipesInFlight.isNotEmpty) {
    final batch = _wipesInFlight.toList();
    await Future.wait(batch).timeout(limit, onTimeout: () => <void>[]);
    _wipesInFlight.removeAll(batch);
  }
}

/// The account whose chat data must be erased before the engine opens for
/// [sessionUser] (null while signed out), or null when there is nothing foreign
/// on this phone. [lastSeen] is the account this process last held. A fresh
/// process has none, so the owner recorded in the keystore stands in for it:
/// a different person signing in on a phone that still holds the previous
/// owner's chat data (a sign-out that never finished, a first launch after a
/// reinstall) wipes it first.
Future<String?> chatOwnerToWipe({
  required ChatStore store,
  required String? lastSeen,
  required String? sessionUser,
}) async {
  if (lastSeen != null && lastSeen != sessionUser) return lastSeen;
  final owner = await store.read(ChatLocalData.ownerKey);
  if (owner != null && owner != sessionUser) return owner;
  return null;
}

/// The explicit sign-out step for chat: erases the departing account's chat
/// keys, history and cached photos from this phone and removes the chat device
/// on the server, best effort. Registered by `SessionController` on its own
/// sign-out hooks, so it runs on every sign-out (log out, session expiry,
/// account deletion, "use a different account" on the splash, the verify-email
/// and pending-deletion screens, a start-up the server refused) whether or not
/// any chat screen or provider is alive. [departing] is the session that is
/// ending; without one, the account recorded as this device's chat owner is
/// wiped instead. Nothing happens where chat is not supported (web): no
/// keystore is bound there (`lib/bindings.dart`).
Future<void> Function() chatWipeHook(Ref ref, Session? Function() departing) =>
    () {
      final run = _wipe(ref, departing());
      final tracked = run.then<void>((_) {}, onError: (_) {});
      _wipesInFlight.add(tracked);
      unawaited(tracked.whenComplete(() => _wipesInFlight.remove(tracked)));
      return run;
    };

/// Erases what an earlier sign-out left in the keystore because it would not answer then (see
/// [ChatLocalData.pendingWipes]). `SessionController` starts it at launch; it is tracked like a sign-out wipe,
/// so the chat engine (which awaits [chatWipeSettled]) never opens before it has finished. Never throws.
Future<void> retryPendingChatWipe(Ref ref) {
  final store = ref.read(chatWipeStoreProvider);
  if (store == null) return Future.value();
  final run = () async {
    try {
      final root = await ref.read(chatWipeRootProvider)();
      await ChatLocalData.retryPendingWipes(root: root, store: store);
    } catch (_) {
      // Left for the next launch or sign-out.
    }
  }();
  _wipesInFlight.add(run);
  unawaited(run.whenComplete(() => _wipesInFlight.remove(run)));
  return run;
}

Future<void> _wipe(Ref ref, Session? session) async {
  final store = ref.read(chatWipeStoreProvider);
  if (store == null) return;
  final root = await ref.read(chatWipeRootProvider)();
  String? userId = session?.userId;
  if (userId == null) {
    try {
      userId = await store.read(ChatLocalData.ownerKey);
    } catch (_) {
      // The keystore will not say whose data this is: the files go now, the entries are retried later.
      await ChatLocalData.wipeUnknownOwner(root);
      return;
    }
  }
  if (userId == null) return;
  await ChatLocalData.wipeAccount(
    root: root,
    store: store,
    userId: userId,
    revoke: session == null
        ? null
        : (deviceId) => ref
              .read(chatDeviceRevokerProvider)(session, deviceId)
              .timeout(chatRevokeTimeout),
  );
}
