import 'dart:convert';
import 'dart:io';

import 'chat_store.dart';

/// Everything the chat keeps on this device, and how it goes away.
///
/// What is kept: secure-storage entries named `hiyall.chat.<userId>.*` (the
/// pickle key, the Olm account and sessions, pinned peer keys, history, the
/// outbox index, verification marks) and, in the app's private folder, the
/// encrypted photo cache (`chat_blobs`) and unsent uploads (`chat_outbox`).
///
/// It is erased on sign-out and on account deletion. It is also erased on the
/// first launch after a reinstall: on iOS the Keychain survives deleting the
/// app, so a marker file in the app's folder (which does go with the app) tells
/// a fresh install from a normal launch. The Keychain items are written
/// "first unlock, this device only", so they never reach a backup or another
/// phone either.
class ChatLocalData {
  const ChatLocalData._();

  /// Prefix of every per-account entry.
  static String prefix(String userId) => 'hiyall.chat.$userId.';

  /// Every chat entry of any account starts with this.
  static const anyPrefix = 'hiyall.chat.';

  /// The account whose data this device holds; lets a sign-out that happens
  /// before the engine was built in this process still find what to erase.
  static const ownerKey = 'hiyall.chatowner';

  /// A server-side removal of this device that could not be sent yet.
  static String pendingRevokeKey(String userId) => 'hiyall.chatrevoke.$userId';

  static const markerName = 'chat_install_marker';
  static const folders = ['chat_blobs', 'chat_outbox', 'chat_state'];

  static final _drains = <String, Future<void> Function()>{};

  /// A running engine of [userId] registers how to stop it (see [ChatEngine.dispose]), so that a wipe of that
  /// account, whoever starts it, first stops the engine and waits for the work it had in flight: nothing it
  /// was doing can write a file or an entry back afterwards.
  static void registerDrain(String userId, Future<void> Function() drain) =>
      _drains[userId] = drain;

  /// Forgets a registration, if it is still [drain] (not another engine's).
  static void unregisterDrain(String userId, Future<void> Function() drain) {
    if (_drains[userId] == drain) _drains.remove(userId);
  }

  /// Records the device id of [userId] to remove on the server later.
  static Future<void> rememberRevoke(
    ChatStore store,
    String userId,
    String deviceId,
  ) => store.write(pendingRevokeKey(userId), deviceId);

  /// The device id still to be removed on the server for [userId], or null.
  static Future<String?> pendingRevoke(ChatStore store, String userId) =>
      store.read(pendingRevokeKey(userId));

  static Future<void> clearPendingRevoke(ChatStore store, String userId) =>
      store.delete(pendingRevokeKey(userId));

  /// Erases one account's chat data from this device. [revoke] removes the
  /// chat device on the server; when it is missing or fails, the device id is
  /// remembered and the next launch retries (see [ChatEngine.start]).
  static Future<void> wipeAccount({
    required Directory root,
    required ChatStore store,
    required String userId,
    Future<void> Function(String deviceId)? revoke,
  }) async {
    // Stop the account's engine first and wait for what it was doing (a poll, a send, an upload).
    final drain = _drains.remove(userId);
    if (drain != null) {
      try {
        await drain();
      } catch (_) {
        // Whatever could not be waited for can no longer write.
      }
    }
    final deviceId = await store.read('${prefix(userId)}deviceId');
    if (deviceId != null) {
      var removed = false;
      if (revoke != null) {
        try {
          await revoke(deviceId);
          removed = true;
        } catch (_) {
          // Offline or signed out already: retried below.
        }
      }
      if (!removed) await rememberRevoke(store, userId, deviceId);
    }
    await deleteKeysWithPrefix(store, prefix(userId));
    if (await store.read(ownerKey) == userId) await store.delete(ownerKey);
    await wipeFiles(root);
  }

  /// The explicit "Reset chat on this phone" for a platform keystore that cannot be opened on launch after
  /// launch (audit CHAT-N4): erases [userId]'s chat data like [wipeAccount], but without trusting the keystore
  /// to answer. The files go first. Then the account's entries are deleted one by one; when the keystore will
  /// not do that, [eraseEverything] clears all of it (that also signs the person out of anything else kept
  /// there, which is why it is the last resort). The old device id is remembered for removal on the server when
  /// the keystore still says what it was; otherwise the device stays on the account's list until it is removed
  /// there or goes stale. Throws [ChatStorageUnavailable] when nothing worked.
  static Future<void> resetAfterStorageFailure({
    required Directory root,
    required ChatStore store,
    required String userId,
    Future<void> Function()? eraseEverything,
  }) async {
    final drain = _drains.remove(userId);
    if (drain != null) {
      try {
        await drain();
      } catch (_) {}
    }
    try {
      final deviceId = await store.read('${prefix(userId)}deviceId');
      if (deviceId != null) await rememberRevoke(store, userId, deviceId);
    } catch (_) {
      // The keystore is what is broken.
    }
    await wipeFiles(root);
    try {
      await deleteKeysWithPrefix(store, prefix(userId));
      if (await store.read(ownerKey) == userId) await store.delete(ownerKey);
    } catch (_) {
      if (eraseEverything == null) throw const ChatStorageUnavailable();
      await eraseEverything();
    }
  }

  /// Removes the photo cache and unsent uploads; best effort.
  static Future<void> wipeFiles(Directory root) async {
    for (final name in folders) {
      try {
        final dir = Directory('${root.path}/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // A locked file goes with the app's data at the latest.
      }
    }
  }

  /// Notes that this device holds [userId]'s chat data.
  static Future<void> markOwner(ChatStore store, String userId) async {
    if (await store.read(ownerKey) != userId) {
      await store.write(ownerKey, userId);
    }
  }

  /// Erases whatever a previous install left in the keychain. Call before the
  /// engine starts. Returns the number of accounts' data that was erased; the
  /// old device ids are remembered so the server can be told.
  static Future<int> eraseAfterReinstall({
    required Directory root,
    required ChatStore store,
  }) async {
    final marker = File('${root.path}/$markerName');
    if (await marker.exists()) return 0;
    var accounts = 0;
    final left = [
      for (final k in await store.keys())
        if (k.startsWith(anyPrefix) &&
            !k.startsWith('hiyall.chatrevoke.') &&
            k != ownerKey)
          k,
    ];
    if (left.isNotEmpty) {
      final users = <String>{};
      for (final k in left) {
        final rest = k.substring(anyPrefix.length);
        final dot = rest.indexOf('.');
        if (dot > 0) users.add(rest.substring(0, dot));
      }
      for (final user in users) {
        final deviceId = await store.read('${prefix(user)}deviceId');
        if (deviceId != null) await rememberRevoke(store, user, deviceId);
        await deleteKeysWithPrefix(store, prefix(user));
        accounts++;
      }
      await store.delete(ownerKey);
    }
    await wipeFiles(root);
    await root.create(recursive: true);
    await marker.writeAsString(
      jsonEncode({'at': DateTime.now().toUtc().toIso8601String()}),
      flush: true,
    );
    return accounts;
  }
}
