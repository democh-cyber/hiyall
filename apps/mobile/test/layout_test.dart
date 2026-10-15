import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/state.dart';

import 'spaces_test.dart' show SpacesFake;
import 'widget_test.dart' show SignedIn;
import 'support/fixtures.dart';

/// Every main page on the smallest common phone, at normal and double text.
void main() {
  for (final path in [
    '/home',
    '/discover',
    '/notifications',
    '/profile',
    '/profile/settings',
    '/profile/sessions',
    '/spaces',
    '/spaces/circle',
    '/people',
    '/discover/person/$nikoId',
    '/person/$nikoId',
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$path fits 320 wide at text x$scale', (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(SpacesFake()..blocked = false),
            sessionProvider.overrideWith(SignedIn.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const HiyallApp(),
          ),
        );
        await tester.pumpAndSettle();
        container.read(routerProvider).go(path);
        await tester.pumpAndSettle();
        final errors = <Object>[];
        for (Object? e; (e = tester.takeException()) != null;) {
          errors.add(e!);
        }
        expect(errors, isEmpty);
      });
    }
  }
}
