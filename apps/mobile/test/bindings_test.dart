import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show routerProvider;
import 'package:hiyall/bindings.dart';
import 'package:hiyall/core/app_bindings.dart';
import 'package:hiyall/core/push/push_controller.dart';
import 'package:hiyall/core/state.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

void main() {
  test('core does nothing on its own: no engine, links go nowhere', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(chatEngineSourceProvider.future), isNull);
    container.read(routeOpenerProvider)('/chats');
  });

  test('the app bindings send a push tap through the router', () async {
    final container = ProviderContainer(
      overrides: [
        ...appBindings(),
        apiProvider.overrideWithValue(FakeApi()),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);
    container.read(pushOpenerProvider)('/profile');
    await Future<void>.delayed(Duration.zero);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
  });
}
