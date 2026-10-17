import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/state.dart';

import 'auth_test.dart' show FakeGateway;
import 'signout_paths_test.dart'
    show ColdApi, QuietApi, Rig, SignedInReal, SlowStore;
import 'support/fixtures.dart';

/// An API that accepts the credential and says who it is.
class OkApi extends QuietApi {
  OkApi(this.userId);
  final String userId;
  @override
  Future<Profile> profile(Session s) async => Profile(
    userId: userId,
    username: 'someone',
    displayName: 'Someone',
    bio: '',
    profession: '',
    version: '1',
  );
  @override
  Future<OnboardingStatus> onboarding(Session s) async =>
      const OnboardingStatus(true, '2026-10-01');
}

class GatewayThatFails extends FakeGateway {
  GatewayThatFails(super.user);
  @override
  Future<void> signOut() async => throw StateError('keychain');
}

void main() {
  late Directory root;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('hiyall-round4');
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  const google = AuthUser(
    uid: 'uid-1',
    method: AuthMethod.google,
    emailVerified: true,
  );

  Future<Rig> coldStart(
    ApiClient api, {
    String? lastUser,
    FakeGateway? gateway,
  }) async {
    final rig = Rig(
      root,
      api: api,
      gateway: gateway ?? FakeGateway(google),
      lastUser: lastUser,
    );
    addTearDown(rig.container.dispose);
    rig.container.read(sessionProvider);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return rig;
  }

  group('only UNAUTHENTICATED ends a session at start-up (NEW-2)', () {
    test('401 APP_CHECK_REQUIRED keeps the chat data, the drafts and the signed-in provider account', () async {
      final rig = await coldStart(
        ColdApi(code: appCheckRequiredCode),
        lastUser: anjaliId,
      );
      expect(rig.container.read(sessionProvider).hasError, isTrue);
      expect(rig.chatKept, isTrue);
      expect(rig.residueGone, isFalse);
      expect(rig.imageWipes, 0);
      expect(rig.lastUsers.value, anjaliId, reason: 'nothing was signed out');
      expect(
        rig.container.read(sessionExpiredProvider),
        isFalse,
        reason: 'no "you were signed out" notice either',
      );
    });

    test('a 401 with no error code at all (a proxy) proves nothing', () async {
      final rig = await coldStart(ColdApi(code: null));
      expect(rig.chatKept, isTrue);
    });

    test('a 401 UNAUTHENTICATED still wipes', () async {
      final rig = await coldStart(ColdApi(), lastUser: anjaliId);
      expect(rig.chatGone, isTrue);
    });

    test('an APP_CHECK_REQUIRED answer from the deletion check is not a dead credential either', () async {
      final rig = await coldStart(
        ColdApi(
          statusAnswer: const ApiFailure('app', 401, appCheckRequiredCode),
        ),
      );
      expect(rig.chatKept, isTrue);
    });
  });

  group('a provider-initiated sign-out runs the hooks (NEW-5)', () {
    test('the identity provider dropping a live session wipes the account and says why', () async {
      final gateway = FakeGateway(google);
      final rig = await coldStart(OkApi(anjaliId), gateway: gateway);
      expect(
        rig.container.read(sessionProvider).asData?.value?.userId,
        anjaliId,
      );
      expect(rig.chatKept, isTrue);
      expect(rig.residueGone, isFalse);

      await gateway.signOut(); // a revoked refresh token, a disabled account...
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(rig.container.read(sessionProvider).asData?.value, isNull);
      expect(rig.chatGone, isTrue);
      expect(rig.residueGone, isTrue);
      expect(rig.container.read(sessionExpiredProvider), isTrue);
      expect(rig.lastUsers.value, isNull);
    });

    test('the app\'s own logout runs the hooks once, not twice', () async {
      final gateway = FakeGateway(google);
      final rig = await coldStart(OkApi(anjaliId), gateway: gateway);
      await rig.session.logout();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rig.imageWipes, 1);
      expect(rig.container.read(sessionExpiredProvider), isFalse);
    });

    test('signing out while signed out does nothing', () async {
      final gateway = FakeGateway(null);
      final rig = await coldStart(QuietApi(), gateway: gateway);
      await gateway.signOut();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.imageWipes, 0);
    });
  });

  group('the last account is remembered across a cold start (NEW-9)', () {
    test('a session that is established is written down', () async {
      final rig = await coldStart(OkApi(anjaliId));
      expect(rig.lastUsers.value, anjaliId);
    });

    test('a cold-start 401 cleans the drafts and choices of the remembered account, then forgets it', () async {
      final rig = await coldStart(ColdApi(), lastUser: anjaliId);
      expect(rig.chatGone, isTrue);
      expect(rig.residueGone, isTrue);
      expect(
        rig.drafts.drafts[nikoId],
        isNotNull,
        reason: 'another account\'s draft stays',
      );
      expect(rig.lastUsers.value, isNull);
    });

    test(
      'signing in as someone else cleans what the remembered account left',
      () async {
        final rig = await coldStart(OkApi(nikoId), lastUser: anjaliId);
        expect(
          rig.container.read(sessionProvider).asData?.value?.userId,
          nikoId,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(rig.drafts.drafts[anjaliId], isNull);
        expect(rig.drafts.drafts[nikoId], isNotNull);
        expect(rig.lastUsers.value, nikoId);
      },
    );

    test('signing in as the same account cleans nothing', () async {
      final rig = await coldStart(OkApi(anjaliId), lastUser: anjaliId);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.drafts.drafts[anjaliId], isNotNull);
    });

    test('a departure that finishes after a new sign-in does not forget the new account', () async {
      final slow = SlowStore();
      final rig = Rig(
        root,
        api: OkApi(nikoId),
        session: sessionProvider.overrideWith(SignedInReal.new),
        chat: slow,
        lastUser: anjaliId,
      );
      addTearDown(rig.container.dispose);
      final controller = rig.session;
      controller.signOutHookTimeout = const Duration(seconds: 5);
      controller.expire(); // hooks start, and block on the keystore
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Meanwhile somebody signs in (a member who keeps their account resumes).
      await controller.resume(const Session('tok2', nikoId));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.lastUsers.value, nikoId);
      slow.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // The old departure is over; it left the new account's note alone.
      expect(rig.lastUsers.value, nikoId);
      expect(rig.container.read(sessionProvider).asData?.value?.userId, nikoId);
      // And its own account was the one cleaned.
      expect(rig.drafts.drafts[anjaliId], isNull);
      expect(rig.drafts.drafts[nikoId], isNotNull);
    });
  });

  group('signOutProvider survives a failing provider sign-out (NEW-10)', () {
    test('the hooks ran, the state is cleared and nothing throws', () async {
      final rig = Rig(
        root,
        api: QuietApi(),
        gateway: GatewayThatFails(google),
        session: sessionProvider.overrideWith(SignedInReal.new),
      );
      addTearDown(rig.container.dispose);
      await rig.session.signOutProvider();
      expect(rig.container.read(sessionProvider).asData?.value, isNull);
      expect(rig.chatGone, isTrue);
      expect(rig.residueGone, isTrue);
    });
  });
}
