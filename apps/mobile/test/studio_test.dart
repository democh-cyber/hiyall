import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/features/design_studio.dart';

import 'design_preview_test.dart' show SignedOut;
import 'widget_test.dart' show FakeApi, SignedIn;

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
  for (final config in [
    (const Size(320, 740), 2.0),
    (const Size(390, 844), 1.0),
    (const Size(1440, 1000), 1.0),
  ]) {
    testWidgets('Every design screen at ${config.$1}, scale ${config.$2}', (
      tester,
    ) async {
      tester.view.physicalSize = config.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [sessionProvider.overrideWith(SignedOut.new)],
      );
      addTearDown(container.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MediaQuery(
            data: MediaQueryData(
              size: config.$1,
              textScaler: TextScaler.linear(config.$2),
            ),
            child: RepaintBoundary(key: capture, child: const KairovaApp()),
          ),
        ),
      );
      for (final dark in [false, true]) {
        container.read(themeProvider.notifier).toggle(dark);
        for (final route in [
          '/design',
          ...designScreens.map((s) => '/design/${s.id}'),
        ]) {
          container.read(routerProvider).go(route);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$route dark=$dark config=$config',
          );
          if (route != '/design') {
            expect(find.byType(PreviewNotice), findsOneWidget);
          }
          if (const bool.fromEnvironment('CAPTURE_DESIGN') &&
              config.$2 == 1 &&
              [
                'welcome',
                'home',
                'chat',
                'my-space',
                'communities',
                'create-post',
                'interests',
              ].any((id) => route == '/design/$id')) {
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
              final file = File(
                '../../.runtime/design-previews/studio-${route.split('/').last}-${config.$1.width.toInt()}-${dark ? 'dark' : 'light'}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              img.dispose();
            });
          }
          final list = find.byType(ListView).first;
          for (
            var i = 0;
            i <
                (route == '/design' ||
                        route.endsWith('/home') ||
                        route.endsWith('/community-feed')
                    ? 12
                    : 3);
            i++
          ) {
            await tester.drag(list, Offset(0, -config.$1.height * .75));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Scrolled $route dark=$dark config=$config',
            );
          }
        }
      }
    });
  }
  testWidgets('Local preview reactions and chat themes work without sending', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [sessionProvider.overrideWith(SignedOut.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KairovaApp(),
      ),
    );
    container.read(routerProvider).go('/design/post-details');
    await tester.pumpAndSettle();
    final love = find.widgetWithText(FilterChip, 'Love');
    await tester.ensureVisible(love);
    await tester.pumpAndSettle();
    await tester.tap(love);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(love).selected, isTrue);
    container.read(routerProvider).go('/design/chat');
    await tester.pumpAndSettle();
    final candy = find.widgetWithText(ChoiceChip, 'Candy');
    await tester.ensureVisible(candy);
    await tester.pumpAndSettle();
    await tester.tap(candy);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(candy).selected, isTrue);
    expect(
      tester
          .widgetList<MessageSurface>(find.byType(MessageSurface))
          .where((s) => s.outgoing)
          .single
          .color,
      const Color(0xfff6bed4),
    );
    final send = find.widgetWithText(FilledButton, 'Send unavailable');
    await tester.scrollUntilVisible(
      send,
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Creation orb opens Vibe preview and keeps changes local', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWithValue(FakeApi()),
          sessionProvider.overrideWith(SignedIn.new),
        ],
        child: const KairovaApp(),
      ),
    );
    await tester.pumpAndSettle();
    // Home's button now creates real posts; the design orbit stays in the gallery.
    showCreationOrbit(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();
    final vibe = find.widgetWithText(ListTile, 'Vibe');
    await tester.ensureVisible(vibe);
    await tester.pumpAndSettle();
    await tester.tap(vibe);
    await tester.pumpAndSettle();
    expect(find.text('What’s your vibe?'), findsOneWidget);
    final gaming = find.widgetWithText(ChoiceChip, 'Gaming');
    await tester.ensureVisible(gaming);
    await tester.pumpAndSettle();
    await tester.tap(gaming);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(gaming).selected, isTrue);
    final preview = find.text('Preview my vibe');
    await tester.ensureVisible(preview);
    await tester.pumpAndSettle();
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.text('Vibe updated in this preview only.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('Screen inventory includes every requested group and unique routes', () {
    expect(designScreens.map((s) => s.id).toSet().length, designScreens.length);
    expect(designScreens.length, greaterThanOrEqualTo(54));
    for (final group in [
      'Authentication',
      'Onboarding',
      'Main',
      'Profile',
      'Chat',
      'Communities',
      'Settings',
    ]) {
      expect(designScreens.any((s) => s.group == group), isTrue);
    }
  });
}
