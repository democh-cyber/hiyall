import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'app_bindings.dart';
import 'app_info.dart';
import 'chat/chat_api.dart';
import 'chat/chat_local_data.dart';

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

/// The explicit sign-out step for chat: erases the departing account's chat
/// keys, history and cached photos from this phone and removes the chat device
/// on the server, best effort. Registered by `SessionController` on its own
/// sign-out hooks, so it runs on log out, session expiry and account deletion
/// whether or not any chat screen or provider is alive. [departing] is the
/// session that is ending; without one, the account recorded as this device's
/// chat owner is wiped instead.
Future<void> Function() chatWipeHook(Ref ref, Session? Function() departing) =>
    () async {
      final store = ref.read(chatWipeStoreProvider);
      if (store == null) return;
      final session = departing();
      final userId =
          session?.userId ?? await store.read(ChatLocalData.ownerKey);
      if (userId == null) return;
      final root = await ref.read(chatWipeRootProvider)();
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
    };
