import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/chat_wipe_hook.dart';
import 'package:hiyall/core/data_delivery.dart';
import 'package:hiyall/core/last_user.dart';
import 'package:hiyall/core/signout_residue.dart';
import 'package:hiyall/core/state.dart';

import 'support/fixtures.dart';

/// A keystore that answers [ChatStorageUnavailable] to everything while [broken].
class FlakyStore extends MemoryChatStore {
  bool broken = false;
  void _check() {
    if (broken) throw const ChatStorageUnavailable('keystore busy');
  }

  @override
  Future<String?> read(String key) async {
    _check();
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    _check();
    return super.delete(key);
  }

  @override
  Future<List<String>> keys() async {
    _check();
    return super.keys();
  }
}

void main() {
  late Directory root;
  late FlakyStore store;
  setUp(() {
    root = Directory.systemTemp.createTempSync('hiyall-pending');
    store = FlakyStore();
    store.values['hiyall.chat.$anjaliId.deviceId'] = 'dev-1';
    store.values['hiyall.chat.$anjaliId.pickleKey'] = 'secret';
    store.values[ChatLocalData.ownerKey] = anjaliId;
    for (final f in ChatLocalData.folders) {
      Directory('${root.path}/$f').createSync(recursive: true);
      File('${root.path}/$f/x').writeAsStringSync('cached');
    }
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  bool filesGone() => ChatLocalData.folders.every(
    (f) => !Directory('${root.path}/$f').existsSync(),
  );
  File marker() => File('${root.path}/${ChatLocalData.pendingWipeName}');

  group(
    'a keystore that errors does not stop the sign-out wipe (round 4, NEW-1)',
    () {
      test('the files go first, the marker is set, nothing throws', () async {
        store.broken = true;
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: anjaliId,
        );
        expect(filesGone(), isTrue);
        expect(marker().existsSync(), isTrue);
        expect(jsonDecode(marker().readAsStringSync())['users'], [anjaliId]);
        // Nothing secret in the marker.
        expect(marker().readAsStringSync(), isNot(contains('secret')));
        expect(
          store.values.containsKey('hiyall.chat.$anjaliId.pickleKey'),
          isTrue,
        );
      });

      test('the retry, once the keystore answers, erases the entries and removes the marker', () async {
        store.broken = true;
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: anjaliId,
        );
        // Still broken: stays pending.
        await ChatLocalData.retryPendingWipes(root: root, store: store);
        expect(marker().existsSync(), isTrue);
        store.broken = false;
        await ChatLocalData.retryPendingWipes(root: root, store: store);
        expect(marker().existsSync(), isFalse);
        expect(
          store.values.keys.where(
            (k) => k.startsWith('hiyall.chat.$anjaliId.'),
          ),
          isEmpty,
        );
        expect(store.values.containsKey(ChatLocalData.ownerKey), isFalse);
        // The device id was remembered for the server before the keys went.
        expect(store.values[ChatLocalData.pendingRevokeKey(anjaliId)], 'dev-1');
      });

      test('a working keystore leaves no marker, and clears an old one for that account', () async {
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: anjaliId,
        );
        expect(marker().existsSync(), isFalse);
        store.values['hiyall.chat.$anjaliId.pickleKey'] = 'again';
        store.broken = true;
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: anjaliId,
        );
        expect(marker().existsSync(), isTrue);
        store.broken = false;
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: anjaliId,
        );
        expect(marker().existsSync(), isFalse);
      });

      test(
        'the next sign-out of another account also finishes the earlier one',
        () async {
          store.broken = true;
          await ChatLocalData.wipeAccount(
            root: root,
            store: store,
            userId: anjaliId,
          );
          store.broken = false;
          store.values['hiyall.chat.$nikoId.pickleKey'] = 'niko';
          await ChatLocalData.wipeAccount(
            root: root,
            store: store,
            userId: nikoId,
          );
          expect(marker().existsSync(), isFalse);
          expect(
            store.values.keys.where((k) => k.startsWith('hiyall.chat.')),
            isEmpty,
          );
        },
      );

      test('a keystore that only fails to list still has its known entries deleted by name', () async {
        final listing = _NoListing()..values.addAll(store.values);
        await ChatLocalData.wipeAccount(
          root: root,
          store: listing,
          userId: anjaliId,
        );
        expect(
          listing.values.containsKey('hiyall.chat.$anjaliId.pickleKey'),
          isFalse,
        );
        expect(filesGone(), isTrue);
        expect(marker().existsSync(), isFalse);
      });

      test('an unknown owner (the keystore will not say) still loses the files and is resolved later', () async {
        await ChatLocalData.wipeUnknownOwner(root);
        expect(filesGone(), isTrue);
        expect(jsonDecode(marker().readAsStringSync())['users'], [
          ChatLocalData.unknownOwner,
        ]);
        store.broken = true;
        await ChatLocalData.retryPendingWipes(root: root, store: store);
        expect(marker().existsSync(), isTrue);
        store.broken = false;
        await ChatLocalData.retryPendingWipes(root: root, store: store);
        expect(marker().existsSync(), isFalse);
        expect(
          store.values.keys.where(
            (k) => k.startsWith('hiyall.chat.$anjaliId.'),
          ),
          isEmpty,
        );
      });
    },
  );

  group('through the app', () {
    ProviderContainer app({Session? signedIn}) {
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(_Quiet()),
          chatWipeStoreProvider.overrideWithValue(store),
          chatWipeRootProvider.overrideWithValue(() async => root),
          chatDeviceRevokerProvider.overrideWithValue((s, id) async {}),
          exportWipeProvider.overrideWithValue(() async {}),
          imageCachesWipeProvider.overrideWithValue(() async {}),
          lastUserStoreProvider.overrideWithValue(MemoryLastUserStore()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('the sign-out hook with a broken keystore and no session still removes the files', () async {
      store.broken = true;
      final container = app();
      await container.read(sessionProvider.notifier).signOutProvider();
      expect(filesGone(), isTrue);
      expect(marker().existsSync(), isTrue);
      expect(jsonDecode(marker().readAsStringSync())['users'], [
        ChatLocalData.unknownOwner,
      ]);
    });

    test(
      'a launch retries the pending wipe before anything opens chat data',
      () async {
        store.broken = true;
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: anjaliId,
        );
        store.broken = false;
        // A new process: the controller starts, and the retry is waited for like a sign-out wipe.
        final container = app();
        container.read(sessionProvider);
        await chatWipeSettled();
        expect(marker().existsSync(), isFalse);
        expect(
          store.values.keys.where(
            (k) => k.startsWith('hiyall.chat.$anjaliId.'),
          ),
          isEmpty,
        );
      },
    );
  });
}

class _NoListing extends MemoryChatStore {
  @override
  Future<List<String>> keys() async => throw const ChatStorageUnavailable();
}

class _Quiet extends ApiClient {
  @override
  Future<void> logout(Session s) async {}
  @override
  Future<void> stopSharingLocation(Session s) async {}
}
