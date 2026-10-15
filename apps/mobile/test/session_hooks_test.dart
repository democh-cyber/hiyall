import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/chat_wipe_hook.dart';
import 'package:hiyall/core/data_delivery.dart';
import 'package:hiyall/core/deep_link.dart';
import 'package:hiyall/core/error_reporting.dart';
import 'package:hiyall/core/state.dart';

import 'support/fixtures.dart';

/// The real [SessionController] (its own `build` runs, so it registers its own
/// sign-out hooks), started already signed in.
class RealSignedIn extends SessionController {
  @override
  AsyncValue<Session?> build() {
    super.build();
    return const AsyncData(Session('tok', anjaliId));
  }
}

class QuietApi extends ApiClient {
  @override
  Future<void> logout(Session s) async {}
  @override
  Future<void> stopSharingLocation(Session s) async {}
}

class Rig {
  Rig(Directory root, {this.revokeFails = false}) : root = root {
    store.values['hiyall.chat.$anjaliId.deviceId'] = 'dev-1';
    store.values['hiyall.chat.$anjaliId.olm'] = 'secret';
    store.values[ChatLocalData.ownerKey] = anjaliId;
    for (final f in ChatLocalData.folders) {
      Directory('${root.path}/$f').createSync(recursive: true);
      File('${root.path}/$f/x').writeAsStringSync('cached');
    }
    container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(QuietApi()),
        sessionProvider.overrideWith(RealSignedIn.new),
        chatWipeStoreProvider.overrideWithValue(store),
        chatWipeRootProvider.overrideWithValue(() async => root),
        chatDeviceRevokerProvider.overrideWithValue((s, id) async {
          revoked.add((s.token, id));
          if (revokeFails) throw StateError('offline');
        }),
        exportWipeProvider.overrideWithValue(() async => exportWipes++),
      ],
    );
  }
  final Directory root;
  final bool revokeFails;
  final store = MemoryChatStore();
  final revoked = <(String, String)>[];
  int exportWipes = 0;
  late final ProviderContainer container;
  SessionController get session => container.read(sessionProvider.notifier);

  bool get chatGone =>
      !store.values.keys.any((k) => k.startsWith('hiyall.chat.$anjaliId.')) &&
      ChatLocalData.folders.every(
        (f) => !Directory('${root.path}/$f').existsSync(),
      );
}

void main() {
  late Directory root;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('hiyall-hooks');
  });
  tearDown(() {
    ErrorReporting.onCapture = null;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('chat wipe is an explicit sign-out step (APP-12)', () {
    test('it runs on logout with no chat screen or provider alive', () async {
      final rig = Rig(root);
      addTearDown(rig.container.dispose);
      await rig.session.logout();
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
      expect(rig.chatGone, isTrue);
      expect(rig.revoked, [
        ('tok', 'dev-1'),
      ], reason: 'the chat device is removed on the server');
      expect(rig.exportWipes, 1);
    });

    test('it runs when the session expires', () async {
      final rig = Rig(root);
      addTearDown(rig.container.dispose);
      rig.session.expire();
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
      expect(rig.container.read(sessionExpiredProvider), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rig.chatGone, isTrue);
      expect(rig.exportWipes, 1);
    });

    test('it runs when the account is deleted (provider sign-out)', () async {
      final rig = Rig(root);
      addTearDown(rig.container.dispose);
      await rig.session.signOutProvider();
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
      expect(rig.chatGone, isTrue);
      expect(rig.exportWipes, 1);
    });

    test('a revoke that fails is remembered for the next launch and the wipe still happens', () async {
      final rig = Rig(root, revokeFails: true);
      addTearDown(rig.container.dispose);
      await rig.session.logout();
      expect(rig.chatGone, isTrue);
      expect(
        rig.store.values[ChatLocalData.pendingRevokeKey(anjaliId)],
        'dev-1',
      );
    });

    test(
      'a revoke that hangs does not hold the wipe past its own limit',
      () async {
        final rig = Rig(root);
        addTearDown(rig.container.dispose);
        final hang = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(QuietApi()),
            sessionProvider.overrideWith(RealSignedIn.new),
            chatWipeStoreProvider.overrideWithValue(rig.store),
            chatWipeRootProvider.overrideWithValue(() async => root),
            chatDeviceRevokerProvider.overrideWithValue((s, id) => hang.future),
            exportWipeProvider.overrideWithValue(() async {}),
          ],
        );
        addTearDown(container.dispose);
        final watch = Stopwatch()..start();
        await container.read(sessionProvider.notifier).logout();
        expect(
          watch.elapsed,
          lessThan(chatRevokeTimeout + const Duration(seconds: 2)),
        );
        expect(rig.chatGone, isTrue);
      },
    );

    test(
      'without a keystore bound there is nothing to wipe and nothing breaks',
      () async {
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(QuietApi()),
            sessionProvider.overrideWith(RealSignedIn.new),
            exportWipeProvider.overrideWithValue(() async {}),
          ],
        );
        addTearDown(container.dispose);
        await container.read(sessionProvider.notifier).logout();
        expect(container.read(sessionProvider).asData?.value, isNull);
      },
    );
  });

  group('sign-out hooks are bounded (APP-7)', () {
    test('a hook that never finishes is cut off, later hooks run and the person is signed out', () async {
      final rig = Rig(root);
      addTearDown(rig.container.dispose);
      final reported = <String>[];
      ErrorReporting.onCapture = (error, fatal) => reported.add('$error');
      rig.session.signOutHookTimeout = const Duration(milliseconds: 80);
      final ran = <String>[];
      rig.session.signOutHooks
        ..add(() => Completer<void>().future)
        ..add(() async => throw StateError('secret detail ana@example.com'))
        ..add(() async => ran.add('last'));
      await rig.session.logout().timeout(const Duration(seconds: 5));
      expect(ran, ['last']);
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
      expect(reported, hasLength(2));
      for (final line in reported) {
        expect(line, contains('sign-out hook failed'));
        expect(
          line,
          isNot(contains('ana@example.com')),
          reason: 'type only, no message',
        );
      }
    });

    test('the default limit is five seconds', () {
      final rig = Rig(root);
      addTearDown(rig.container.dispose);
      expect(rig.session.signOutHookTimeout, const Duration(seconds: 5));
    });
  });

  group('a remembered link goes with the account (APP-1)', () {
    for (final (label, leave)
        in <(String, Future<void> Function(SessionController))>[
          ('logout', (s) => s.logout()),
          ('expiry', (s) async => s.expire()),
          ('account deletion', (s) => s.signOutProvider()),
        ]) {
      test('$label forgets it', () async {
        final rig = Rig(root);
        addTearDown(rig.container.dispose);
        final memory = rig.container.read(deepLinkMemoryProvider)
          ..remember(Uri.parse('/profile/settings'));
        expect(memory.pending, isNotNull);
        await leave(rig.session);
        expect(memory.pending, isNull);
      });
    }
  });
}
