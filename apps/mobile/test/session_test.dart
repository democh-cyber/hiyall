import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';

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
  test('A connection failure keeps the credential until revocation is acknowledged', () async {
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(FailingLogout(null)),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(sessionProvider.notifier).logout(),
      throwsA(isA<ApiFailure>()),
    );
    expect(container.read(sessionProvider).asData?.value?.userId, anjaliId);
  });
}
