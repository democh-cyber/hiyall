import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/state.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class DesignApi extends FakeApi {
  @override
  Future<Map<String, dynamic>> sessions(
    Session session, [
    String? cursor,
  ]) async => {
    'items': [
      {
        'sessionId': 'design-test-session',
        'current': true,
        'createdAt': '2026-10-07T09:00:00Z',
        'expiresAt': '2026-10-08T09:00:00Z',
        'revokedAt': null,
      },
    ],
    'nextCursor': null,
  };
}

class SignedOut extends SessionController {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  final routes = [
    '/home',
    '/chats',
    '/discover',
    '/notifications',
    '/profile',
    '/profile/edit',
    '/profile/privacy',
    '/profile/sessions',
  ];
  for (final size in [
    const Size(390, 844),
    const Size(1440, 1000),
    const Size(320, 740),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('All redesigned routes at $size, text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(DesignApi()),
            sessionProvider.overrideWith(SignedIn.new),
          ],
        );
        addTearDown(container.dispose);
        final capture = GlobalKey();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: RepaintBoundary(key: capture, child: const KairovaApp()),
            ),
          ),
        );
        for (final dark in [false, true]) {
          container.read(themeProvider.notifier).toggle(dark);
          for (final route in routes) {
            container.read(routerProvider).go(route);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$route, dark=$dark, $size, scale=$scale',
            );
            if (scale == 1 &&
                size.width != 320 &&
                const bool.fromEnvironment('CAPTURE_DESIGN')) {
              void repaint(RenderObject render) {
                render.markNeedsPaint();
                render.visitChildren(repaint);
              }

              repaint(capture.currentContext!.findRenderObject()!);
              await tester.pump();
              await tester.runAsync(() async {
                final boundary =
                    capture.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final img = await boundary.toImage(pixelRatio: 1);
                final bytes = await img.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final name = route.replaceAll('/', '-').substring(1);
                final file = File(
                  '../../.runtime/design-previews/$name-${size.width.toInt()}-${dark ? 'dark' : 'light'}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                img.dispose();
              });
            }
            // Traverse long settings/forms too; validate controls below the fold.
            for (var i = 0; i < (route == '/profile/privacy' ? 11 : 2); i++) {
              final lists = find.byType(ListView);
              if (lists.evaluate().isNotEmpty) {
                await tester.drag(lists.last, Offset(0, -size.height * .65));
                await tester.pumpAndSettle();
                expect(
                  tester.takeException(),
                  isNull,
                  reason: 'Scrolled $route, dark=$dark, $size, scale=$scale',
                );
              }
            }
          }
        }
      });
    }
  }
  testWidgets('Welcome adapts to small screens and large text', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(SignedOut.new)],
        child: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 740),
            textScaler: TextScaler.linear(2),
          ),
          child: KairovaApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1500),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
