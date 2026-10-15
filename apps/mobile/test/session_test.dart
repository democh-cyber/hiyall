import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/pending_revoke.dart';
import 'package:hiyall/core/state.dart';

import 'support/fixtures.dart';

class SignedIn extends SessionController {
  @override
  AsyncValue<Session?> build() =>
      const AsyncData(Session('local-test', anjaliId));
}

class FailingLogout extends ApiClient {
  final int? status;
  FailingLogout(this.status);
  @override
  Future<void> logout(Session s) async =>
      throw ApiFailure('Logout failed', status);
}

void main() {
  test('An expired session can be cleared to allow signing in again', () async {
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(FailingLogout(401)),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.notifier).logout();
    expect(container.read(sessionProvider).asData?.value, isNull);
  });
  test('Signing out works offline: the person is signed out and the revoke is queued', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(FailingLogout(null)),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.notifier).logout();
    expect(container.read(sessionProvider).asData?.value, isNull);
    final raw = await const FlutterSecureStorage().read(
      key: 'pending_server_revoke',
    );
    expect(raw, isNotNull);
    expect(jsonDecode(raw!)['token'], 'local-test');
  });

  test('A server error on sign-out also queues the revoke', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(FailingLogout(503)),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.notifier).logout();
    expect(container.read(sessionProvider).asData?.value, isNull);
    expect(
      await const FlutterSecureStorage().read(key: 'pending_server_revoke'),
      isNotNull,
    );
  });

  test(
    'An acknowledged sign-out queues nothing, and a 401 counts as done',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(FailingLogout(401)),
          sessionProvider.overrideWith(SignedIn.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).logout();
      expect(
        await const FlutterSecureStorage().read(key: 'pending_server_revoke'),
        isNull,
      );
    },
  );

  test('A failing sign-out hook does not keep the person signed in, and every hook runs', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(FailingLogout(401)),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    final ran = <String>[];
    container.read(sessionProvider.notifier).signOutHooks
      ..add(() async {
        ran.add('first');
        throw StateError('push token removal failed');
      })
      ..add(() async => ran.add('second'));
    await container.read(sessionProvider.notifier).logout();
    expect(ran, ['first', 'second']);
    expect(container.read(sessionProvider).asData?.value, isNull);
  });

  group('A queued revoke', () {
    Future<(RevokeQueue, _Revoker)> queued(
      DateTime Function() now,
      RevokeOutcome outcome,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      final queue = RevokeQueue(now: now);
      await queue.add('old-token');
      return (queue, _Revoker(outcome));
    }

    test('is sent on the next launch and cleared once acknowledged', () async {
      final (queue, api) = await queued(DateTime.now, RevokeOutcome.revoked);
      await queue.flush(api);
      expect(api.sent, ['old-token']);
      await queue.flush(api);
      expect(api.sent, hasLength(1), reason: 'cleared after success');
    });

    test('stays queued while the server cannot be reached', () async {
      final (queue, api) = await queued(
        DateTime.now,
        RevokeOutcome.unreachable,
      );
      await queue.flush(api);
      await queue.flush(api);
      expect(api.sent, ['old-token', 'old-token']);
    });

    test('is dropped when the session is already gone (401)', () async {
      final (queue, api) = await queued(DateTime.now, RevokeOutcome.gone);
      await queue.flush(api);
      await queue.flush(api);
      expect(api.sent, hasLength(1));
    });

    test(
      'is dropped unsent once the token would have expired anyway',
      () async {
        final (_, api) = await queued(DateTime.now, RevokeOutcome.revoked);
        final late = DateTime.now().add(const Duration(hours: 2));
        await RevokeQueue(now: () => late).flush(api);
        expect(api.sent, isEmpty);
      },
    );
  });
}

class _Revoker extends ApiClient {
  final RevokeOutcome outcome;
  final sent = <String>[];
  _Revoker(this.outcome);
  @override
  Future<RevokeOutcome> revokeQueuedSession(String token) async {
    sent.add(token);
    return outcome;
  }
}
