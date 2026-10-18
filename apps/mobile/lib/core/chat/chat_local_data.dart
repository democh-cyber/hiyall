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

  /// `chat_play` holds the short-lived plaintext of a voice message or video while it plays (the players need a
  /// file) and a recording before it is sealed; it is emptied at every start and removed with the rest.
  static const folders = [
    'chat_blobs',
    'chat_outbox',
    'chat_state',
    'chat_play',
  ];

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

  /// Name of the small file (in the app's private folder, not in the keystore) that lists the accounts whose
  /// keystore entries could not be erased at their sign-out. Retried at every launch and at the next sign-out.
  static const pendingWipeName = 'chat_wipe_pending';

  static File _pendingFile(Directory root) =>
      File('${root.path}/$pendingWipeName');

  /// The accounts whose chat entries are still to be erased from the keystore (see [pendingWipeName]).
  static Future<Set<String>> pendingWipes(Directory root) async {
    try {
      final file = _pendingFile(root);
      if (!await file.exists()) return {};
      final json = jsonDecode(await file.readAsString());
      final users = json is Map ? json['users'] : null;
      return {
        if (users is List)
          for (final u in users)
            if (u is String && u.isNotEmpty) u,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writePending(Directory root, Set<String> users) async {
    final file = _pendingFile(root);
    if (users.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await root.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'users': users.toList()..sort()}),
      flush: true,
    );
  }

  /// Erases one account's chat data from this device. The files go first and nothing about the keystore can
  /// stop them: every keystore step is tried on its own, and when any of them fails (a keystore that is busy,
  /// locked or broken answers [ChatStorageUnavailable] or worse) the account is written to the "wipe pending"
  /// file ([pendingWipeName]) and the wipe is retried at the next launch and the next sign-out
  /// ([retryPendingWipes]). Never throws. [revoke] removes the chat device on the server; when it is missing
  /// or fails, the device id is remembered and the next launch retries (see [ChatEngine.start]).
  static Future<void> wipeAccount({
    required Directory root,
    required ChatStore store,
    required String userId,
    Future<void> Function(String deviceId)? revoke,
  }) async {
    await _wipeOne(root, store, userId, revoke: revoke);
    // Accounts a former sign-out could not finish are tried again now that the keystore may answer.
    await retryPendingWipes(root: root, store: store, except: {userId});
  }

  /// Wipes [userId]: files first, then each keystore step on its own. Keeps the pending file in step.
  static Future<void> _wipeOne(
    Directory root,
    ChatStore store,
    String userId, {
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
    await wipeFiles(root);
    var complete = true;
    String? deviceId;
    try {
      deviceId = await store.read('${prefix(userId)}deviceId');
    } catch (_) {
      complete = false;
    }
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
      if (!removed) {
        try {
          await rememberRevoke(store, userId, deviceId);
        } catch (_) {
          complete = false;
        }
      }
    }
    try {
      await deleteKeysWithPrefix(store, prefix(userId));
    } catch (_) {
      // Listing failed: the names this account's chat can have are deleted one by one.
      try {
        await eraseKnownEntries(store, userId);
      } catch (_) {
        complete = false;
      }
    }
    try {
      if (await store.read(ownerKey) == userId) await store.delete(ownerKey);
    } catch (_) {
      complete = false;
    }
    try {
      final pending = await pendingWipes(root);
      if (complete ? pending.remove(userId) : pending.add(userId)) {
        await _writePending(root, pending);
      }
    } catch (_) {
      // The marker could not be written either: the next sign-out finds the owner key and tries again.
    }
  }

  /// Stands in the "wipe pending" file for an account that could not be named because the keystore would
  /// not say who owns this phone's chat data ([ownerKey]); [retryPendingWipes] resolves it later.
  static const unknownOwner = '?';

  /// A sign-out whose owner could not be read from the keystore: the files go now, the keystore entries
  /// are left for [retryPendingWipes]. Never throws.
  static Future<void> wipeUnknownOwner(Directory root) async {
    await wipeFiles(root);
    try {
      await _writePending(root, {...await pendingWipes(root), unknownOwner});
    } catch (_) {}
  }

  /// Tries again the accounts listed in the "wipe pending" file, except [except]. Run before the chat engine
  /// opens at a launch (see `retryPendingChatWipe`) and after every sign-out wipe. Never throws.
  static Future<void> retryPendingWipes({
    required Directory root,
    required ChatStore store,
    Set<String> except = const {},
  }) async {
    for (final user in await pendingWipes(root)) {
      if (except.contains(user)) continue;
      if (user != unknownOwner) {
        await _wipeOne(root, store, user);
        continue;
      }
      try {
        final owner = await store.read(ownerKey);
        if (owner != null && !except.contains(owner)) {
          await _wipeOne(root, store, owner);
        }
        final left = await pendingWipes(root);
        if (left.remove(unknownOwner)) await _writePending(root, left);
      } catch (_) {
        // The keystore still does not answer: stays pending.
      }
    }
  }

  /// The entries one account's chat keeps in the keystore itself: the three the sealed snapshot leaves there
  /// (`snapKey`, `pickleKey`, `deviceId`) and the names that earlier builds wrote one by one before the snapshot
  /// existed (the `history.<conversation>` entries of those builds are the one family that cannot be named; the
  /// snapshot store moves them into itself the first time it opens). They are what [eraseKnownEntries] deletes
  /// when the keystore cannot list its entries.
  static const keystoreEntryNames = [
    'snapKey',
    'pickleKey',
    'deviceId',
    'state',
    'account',
    'sessions',
    'trust',
    'unwedge',
    'devnotes',
    'verified',
    'outbox',
  ];

  /// Deletes [userId]'s chat entries by name, one by one, without listing the keystore (listing is what fails
  /// when it will not open). It touches nothing else: no other account, no push or say-hi preference, no story
  /// draft, no queued session revoke. Every entry is tried; when any could not be removed it throws
  /// [ChatStorageUnavailable] (a stored key that cannot be deleted must not be reported as gone).
  static Future<void> eraseKnownEntries(ChatStore store, String userId) async {
    Object? failure;
    for (final name in keystoreEntryNames) {
      try {
        await store.delete('${prefix(userId)}$name');
      } catch (error) {
        failure = error;
      }
    }
    if (failure != null) throw ChatStorageUnavailable(failure);
  }

  /// The explicit "Reset chat on this phone" for a platform keystore that cannot be opened on launch after
  /// launch (audit CHAT-N4): erases [userId]'s chat data like [wipeAccount], but without trusting the keystore
  /// to answer. The files go first. Then the account's entries are deleted by listing the keystore; when it
  /// cannot be listed, they are deleted by name ([eraseKnownEntries]). Either way only this account's chat
  /// entries go: other accounts' chat data, notification and say-hi preferences, the story draft and a queued
  /// session revoke stay (round 4, CHAT-N7: the earlier last resort cleared the whole keystore). The old device
  /// id is remembered for removal on the server when the keystore still says what it was; otherwise the device
  /// stays on the account's list until it is removed there or goes idle. Throws [ChatStorageUnavailable] when
  /// nothing worked.
  static Future<void> resetAfterStorageFailure({
    required Directory root,
    required ChatStore store,
    required String userId,
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
    } catch (_) {
      await eraseKnownEntries(store, userId);
    }
    try {
      if (await store.read(ownerKey) == userId) await store.delete(ownerKey);
    } catch (_) {
      // Only a marker; the engine writes it again at its next start.
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
