import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/bindings.dart' show chatWipeStoreWhere;
import 'package:hiyall/core/account_state.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/chat_wipe_hook.dart';
import 'package:hiyall/core/data_delivery.dart';
import 'package:hiyall/core/home_prefs.dart';
import 'package:hiyall/core/last_user.dart';
import 'package:hiyall/core/picked_file.dart';
import 'package:hiyall/core/push/push_prefs.dart';
import 'package:hiyall/core/say_hi_prefs.dart';
import 'package:hiyall/core/signout_residue.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/story_draft.dart';

import 'auth_test.dart' show FakeGateway;
import 'support/fixtures.dart';

/// A signed-out controller: the real one, started with no session.
class NoSession extends SessionController {
  @override
  AsyncValue<Session?> build() {
    super.build();
    return const AsyncData(null);
  }
}

class SignedInReal extends SessionController {
  @override
  AsyncValue<Session?> build() {
    super.build();
    return const AsyncData(Session('tok', anjaliId));
  }
}

/// Holds [keys] (the first thing the account wipe does after reading the device id) until released.
class SlowStore extends MemoryChatStore {
  final gate = Completer<void>();
  @override
  Future<List<String>> keys() async {
    await gate.future;
    return super.keys();
  }
}

class QuietApi extends ApiClient {
  @override
  Future<void> logout(Session s) async {}
  @override
  Future<void> stopSharingLocation(Session s) async {}
}

/// What the server says to a start-up with a dead credential.
class ColdApi extends ApiClient {
  ColdApi({this.statusAnswer, this.code = 'UNAUTHENTICATED'});

  /// The error code the server answers the profile read with (a dead credential: UNAUTHENTICATED).
  final String? code;

  /// Null: the deletion check itself answers 401. Otherwise what it returns.
  final Object? statusAnswer;

  @override
  Future<Profile> profile(Session s) async =>
      throw ApiFailure('Your session has expired.', 401, code);

  @override
  Future<DeletionStatus> deletionStatus(Session s) async {
    final answer = statusAnswer;
    if (answer == null) throw ApiFailure('expired', 401, code);
    if (answer is DeletionStatus) return answer;
    throw answer;
  }

  @override
  Future<void> logout(Session s) async {}
}

class Rig {
  Rig(
    this.root, {
    Override? session,
    ApiClient? api,
    ChatStore? chat,
    FakeGateway? gateway,
    String owner = anjaliId,
    String? lastUser,
  }) : store = chat ?? MemoryChatStore() {
    lastUsers.value = lastUser;
    final mem = store;
    if (mem is MemoryChatStore) {
      mem.values['hiyall.chat.$owner.deviceId'] = 'dev-1';
      mem.values['hiyall.chat.$owner.olm'] = 'secret';
      mem.values[ChatLocalData.ownerKey] = owner;
    }
    for (final f in ChatLocalData.folders) {
      Directory('${root.path}/$f').createSync(recursive: true);
      File('${root.path}/$f/x').writeAsStringSync('cached');
    }
    drafts.drafts[anjaliId] = const StoryDraft(text: 'unsent').encode();
    homePrefs.hidden.add(anjaliId);
    sayHi.confirmedBy.add(anjaliId);
    sayHi.sentBy[anjaliId] = {'x': DateTime.utc(2026, 1, 1)};
    push.off.add(anjaliId);
    push.notNow[anjaliId] = DateTime.utc(2026, 1, 1);
    drafts.drafts[nikoId] = const StoryDraft(text: 'other').encode();
    container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api ?? QuietApi()),
        ?session,
        if (gateway != null) authGatewayProvider.overrideWithValue(gateway),
        chatWipeStoreProvider.overrideWithValue(store),
        chatWipeRootProvider.overrideWithValue(() async => root),
        chatDeviceRevokerProvider.overrideWithValue((s, id) async {}),
        exportWipeProvider.overrideWithValue(() async {}),
        storyDraftStoreProvider.overrideWithValue(drafts),
        homePrefsStoreProvider.overrideWithValue(homePrefs),
        sayHiPrefsStoreProvider.overrideWithValue(sayHi),
        pushPrefsStoreProvider.overrideWithValue(push),
        imageCachesWipeProvider.overrideWithValue(() async => imageWipes++),
        lastUserStoreProvider.overrideWithValue(lastUsers),
        pickerTempSweepProvider.overrideWithValue(() async => pickerSweeps++),
      ],
    );
  }

  final lastUsers = MemoryLastUserStore();
  int pickerSweeps = 0;
  final Directory root;
  final ChatStore store;
  final drafts = MemoryStoryDraftStore();
  final homePrefs = MemoryHomePrefsStore();
  final sayHi = MemorySayHiPrefsStore();
  final push = MemoryPushPrefsStore();
  int imageWipes = 0;
  late final ProviderContainer container;
  SessionController get session => container.read(sessionProvider.notifier);

  bool get chatGone {
    final mem = store;
    final keysGone =
        mem is! MemoryChatStore ||
        !mem.values.keys.any((k) => k.startsWith('hiyall.chat.'));
    return keysGone &&
        ChatLocalData.folders.every(
          (f) => !Directory('${root.path}/$f').existsSync(),
        );
  }

  bool get chatKept {
    final mem = store as MemoryChatStore;
    return mem.values.containsKey('hiyall.chat.$anjaliId.olm') &&
        ChatLocalData.folders.every(
          (f) => Directory('${root.path}/$f').existsSync(),
        );
  }

  bool get residueGone =>
      drafts.drafts[anjaliId] == null &&
      !homePrefs.hidden.contains(anjaliId) &&
      !sayHi.confirmedBy.contains(anjaliId) &&
      sayHi.sentBy[anjaliId] == null &&
      !push.off.contains(anjaliId) &&
      push.notNow[anjaliId] == null &&
      imageWipes >= 1 &&
      pickerSweeps >= 1;
}

void main() {
  late Directory root;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('hiyall-paths');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the wipe runs on every sign-out path, session or not (APP-N4)', () {
    test('logout with no session (pending-deletion sign-out) wipes by the remembered owner', () async {
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(NoSession.new),
      );
      addTearDown(rig.container.dispose);
      rig.container.read(pendingAccountProvider.notifier).set(null);
      await rig.session.logout();
      expect(rig.chatGone, isTrue);
      expect(rig.imageWipes, greaterThanOrEqualTo(1));
    });

    test('signOutProvider with no session (splash "Use a different account") wipes too', () async {
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(NoSession.new),
      );
      addTearDown(rig.container.dispose);
      await rig.session.signOutProvider();
      expect(rig.chatGone, isTrue);
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
    });

    test(
      'the verify-email sign-out wipes and clears the waiting state',
      () async {
        final rig = Rig(
          root,
          session: sessionProvider.overrideWith(NoSession.new),
        );
        addTearDown(rig.container.dispose);
        rig.container
            .read(awaitingVerificationProvider.notifier)
            .set(const AuthUser(uid: 'u', method: AuthMethod.password));
        await rig.session.signOutProvider();
        expect(rig.chatGone, isTrue);
        expect(rig.container.read(awaitingVerificationProvider), isNull);
      },
    );

    test(
      'signOutProvider with a session (after deletion) still wipes',
      () async {
        final rig = Rig(
          root,
          session: sessionProvider.overrideWith(SignedInReal.new),
        );
        addTearDown(rig.container.dispose);
        await rig.session.signOutProvider();
        expect(rig.chatGone, isTrue);
        expect(rig.residueGone, isTrue);
      },
    );

    test('with nothing recorded as owner there is nothing to wipe and nothing breaks', () async {
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(NoSession.new),
      );
      addTearDown(rig.container.dispose);
      (rig.store as MemoryChatStore).values.clear();
      await rig.session.logout();
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
    });

    group('a start-up the server refuses (cold-start 401)', () {
      Future<Rig> coldStart(ApiClient api) async {
        final gateway = FakeGateway(
          const AuthUser(
            uid: 'uid-1',
            method: AuthMethod.google,
            emailVerified: true,
          ),
        );
        final rig = Rig(root, api: api, gateway: gateway);
        addTearDown(rig.container.dispose);
        rig.container.read(sessionProvider);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return rig;
      }

      test('a dead credential wipes the chat data left on the phone', () async {
        final rig = await coldStart(ColdApi());
        expect(rig.container.read(sessionProvider).hasError, isTrue);
        expect(rig.chatGone, isTrue);
        expect(rig.imageWipes, greaterThanOrEqualTo(1));
      });

      test(
        'an account in its deletion grace period keeps its chat data',
        () async {
          final rig = await coldStart(
            ColdApi(
              statusAnswer: DeletionStatus(
                pending: true,
                dueAt: DateTime.utc(2026, 12, 1),
                canCancel: true,
              ),
            ),
          );
          expect(rig.container.read(pendingAccountProvider), isNotNull);
          expect(rig.chatKept, isTrue);
        },
      );

      test('a check that could not be answered (offline) proves nothing and wipes nothing', () async {
        final rig = await coldStart(
          ColdApi(statusAnswer: const ApiFailure('offline', null, 'OFFLINE')),
        );
        expect(rig.container.read(sessionProvider).hasError, isTrue);
        expect(rig.chatKept, isTrue);
      });
    });

    test('a different person signing in finds the previous owner to wipe (first launch, another account)', () async {
      final store = MemoryChatStore()
        ..values[ChatLocalData.ownerKey] = anjaliId;
      // A fresh process: nothing remembered in memory, the keystore says Anjali.
      expect(
        await chatOwnerToWipe(
          store: store,
          lastSeen: null,
          sessionUser: nikoId,
        ),
        anjaliId,
      );
      // The same person coming back keeps their data.
      expect(
        await chatOwnerToWipe(
          store: store,
          lastSeen: null,
          sessionUser: anjaliId,
        ),
        isNull,
      );
      // In-process memory wins over the keystore.
      expect(
        await chatOwnerToWipe(
          store: store,
          lastSeen: nikoId,
          sessionUser: anjaliId,
        ),
        nikoId,
      );
      // Signed out: whoever owns it goes; nobody owns it: nothing.
      expect(
        await chatOwnerToWipe(store: store, lastSeen: null, sessionUser: null),
        anjaliId,
      );
      expect(
        await chatOwnerToWipe(
          store: MemoryChatStore(),
          lastSeen: null,
          sessionUser: nikoId,
        ),
        isNull,
      );
    });
  });

  group('a slow wipe is waited for (APP-N8)', () {
    test('the hook may time out, but chatWipeSettled only completes when the wipe is done', () async {
      final slow = SlowStore();
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(SignedInReal.new),
        chat: slow,
      );
      addTearDown(rig.container.dispose);
      rig.session.signOutHookTimeout = const Duration(milliseconds: 60);
      await rig.session.logout();
      // Signed out already: the hook was cut off after 60 ms.
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
      var settled = false;
      final waiting = chatWipeSettled().then((_) => settled = true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(settled, isFalse, reason: 'the wipe is still running');
      expect(rig.chatGone, isFalse);
      slow.gate.complete();
      await waiting;
      expect(settled, isTrue);
      expect(rig.chatGone, isTrue);
    });

    test('a wipe that hangs is waited for only up to the limit', () async {
      final slow = SlowStore();
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(SignedInReal.new),
        chat: slow,
      );
      addTearDown(rig.container.dispose);
      rig.session.signOutHookTimeout = const Duration(milliseconds: 30);
      await rig.session.logout();
      final watch = Stopwatch()..start();
      await chatWipeSettled(limit: const Duration(milliseconds: 120));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      slow.gate.complete();
      await chatWipeSettled();
    });

    test('with no wipe running it returns at once', () async {
      await chatWipeSettled().timeout(const Duration(seconds: 1));
    });
  });

  group('what a departing account leaves besides chat (wipe residue)', () {
    test('logout removes the story draft, Home, Say hi and push choices of that user and the image caches', () async {
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(SignedInReal.new),
      );
      addTearDown(rig.container.dispose);
      expect(rig.residueGone, isFalse);
      await rig.session.logout();
      expect(rig.residueGone, isTrue);
      expect(
        rig.drafts.drafts[nikoId],
        isNotNull,
        reason: 'another account’s draft is not this sign-out’s business',
      );
    });

    test('session expiry does the same', () async {
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(SignedInReal.new),
      );
      addTearDown(rig.container.dispose);
      rig.session.expire();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rig.residueGone, isTrue);
    });

    test('a failing step does not stop the others or the sign-out', () async {
      final rig = Rig(
        root,
        session: sessionProvider.overrideWith(SignedInReal.new),
      );
      addTearDown(rig.container.dispose);
      final broken = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(QuietApi()),
          sessionProvider.overrideWith(SignedInReal.new),
          chatWipeStoreProvider.overrideWithValue(rig.store),
          chatWipeRootProvider.overrideWithValue(() async => root),
          chatDeviceRevokerProvider.overrideWithValue((s, id) async {}),
          exportWipeProvider.overrideWithValue(() async {}),
          storyDraftStoreProvider.overrideWithValue(_ThrowingDrafts()),
          homePrefsStoreProvider.overrideWithValue(rig.homePrefs),
          sayHiPrefsStoreProvider.overrideWithValue(rig.sayHi),
          pushPrefsStoreProvider.overrideWithValue(rig.push),
          imageCachesWipeProvider.overrideWithValue(
            () async => rig.imageWipes++,
          ),
        ],
      );
      addTearDown(broken.dispose);
      await broken.read(sessionProvider.notifier).logout();
      expect(broken.read(sessionProvider).asData?.value, isNull);
      expect(rig.homePrefs.hidden, isNot(contains(anjaliId)));
      expect(rig.push.off, isNot(contains(anjaliId)));
      expect(rig.imageWipes, 1);
    });
  });

  group('no chat keystore where chat does not exist (APP-N5)', () {
    test('web and desktop builds bind no store, so nothing is read', () {
      var opened = 0;
      expect(
        chatWipeStoreWhere(false, () {
          opened++;
          return MemoryChatStore();
        }),
        isNull,
      );
      expect(opened, 0);
      expect(chatWipeStoreWhere(true, MemoryChatStore.new), isNotNull);
    });

    test(
      'with no store bound the hook is a no-op that does not report anything',
      () async {
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(QuietApi()),
            sessionProvider.overrideWith(SignedInReal.new),
            exportWipeProvider.overrideWithValue(() async {}),
            imageCachesWipeProvider.overrideWithValue(() async {}),
          ],
        );
        addTearDown(container.dispose);
        await container.read(sessionProvider.notifier).logout();
        await chatWipeSettled();
      },
    );
  });
}

class _ThrowingDrafts extends MemoryStoryDraftStore {
  @override
  Future<void> forget(String userId) async => throw StateError('keystore');
}
