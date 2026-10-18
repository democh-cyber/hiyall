import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart' show ImperativeRouteMatch;
import 'package:hiyall/app.dart';
import 'package:hiyall/core/state.dart';

import '../widget_test.dart' show FakeApi, SignedIn;

/// Runs the whole app against [api], signed in, and goes to [path].
Future<ProviderContainer> launchApp(
  WidgetTester tester,
  FakeApi api,
  String path, {
  Size size = const Size(390, 844),
  double textScale = 1,
  TextDirection? direction,
  Brightness? brightness,
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  if (brightness != null) {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }
  api.blocked = false;
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
      if (direction != null)
        textDirectionOverrideProvider.overrideWithValue(direction),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HiyallApp()),
  );
  await tester.pumpAndSettle();
  if (path != '/home') {
    container.read(routerProvider).go(path);
    await tester.pumpAndSettle();
  }
  return container;
}

/// The location the app is showing, including a screen opened with `context.push` (which go_router keeps
/// apart from the page-based location).
String where(ProviderContainer c) {
  final config = c.read(routerProvider).routerDelegate.currentConfiguration;
  final last = config.last;
  return (last is ImperativeRouteMatch ? last.matches.uri : config.uri)
      .toString();
}
