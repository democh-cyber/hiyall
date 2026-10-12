import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class SimpleDiscoverApi extends FakeApi {
  final searches = <Map<String, dynamic>>[];
  @override
  Future<Profile> profile(Session s) async => const Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: '',
    profession: '',
    version: '1',
    languages: [ProfileLanguage('en')],
    interests: ['Music'],
    currentVibe: 'Chill',
  );

  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async {
    searches.add(Map.from(filters));
    return {
      'items': [
        for (var i = 0; i < 16; i++)
          {
            'userId': 'fixture-person-$i',
            'username': 'fixture_$i',
            'displayName': [
              'Ari',
              'Jules',
              'Mina',
              'Noor',
              'Kai',
              'Rey',
            ][i % 6],
            'country': ['IN', 'KR', 'JP'][i % 3],
            'headline': [
              'Learning Korean through dramas',
              'Quiet mornings & good books',
              'Film photos + late night ramen',
            ][i % 3],
            'languages': [
              {'code': 'en', 'level': 'fluent'},
              {'code': 'ko', 'level': 'basic'},
            ],
            'interests': ['Music'],
            'currentVibe': 'Chill',
          },
      ],
      'nextCursor': null,
    };
  }

  @override
  Future<ApiPage<SocialSpace>> spaces(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) async => const ApiPage([], null);
}

void main() {
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

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_SIMPLE_DISCOVER')) return;
    void repaint(RenderObject object) {
      object.markNeedsPaint();
      object.visitChildren(repaint);
    }

    repaint(key.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('../../.runtime/simple-discover/$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'Discover opens directly on people and retains spaces and filter navigation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = SimpleDiscoverApi();
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
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
      api.searches.clear();
      container.read(routerProvider).go('/discover');
      await tester.pumpAndSettle();
      expect(api.searches, hasLength(1));
      expect(find.text('Find your people.'), findsOneWidget);
      expect(find.text('Ari').first.hitTestable(), findsOneWidget);
      expect(find.text('More people to meet'), findsNothing);
      expect(find.text('Find people'), findsNothing);
      await tester.tap(find.byTooltip('Filter people'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-content')), findsOneWidget);
      await tester.tap(find.byTooltip('Close filters'));
      await tester.pumpAndSettle();
      expect(api.searches, hasLength(1));
      await tester.tap(find.byTooltip('Explore Discover'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discover-tab-circles')));
      await tester.pumpAndSettle();
      expect(find.text('Explore circles'), findsOneWidget);
      await tester.tap(find.byTooltip('Explore Discover'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discover-tab-moments')));
      await tester.pumpAndSettle();
      expect(find.text('Happening now'), findsOneWidget);
      await tester.tap(find.byTooltip('Explore Discover'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discover-tab-people')));
      await tester.pumpAndSettle();
      expect(find.text('Ari').first.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Simple people rows fit both themes, small phones, and enlarged text',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final (size, scale) in [
        (const Size(390, 844), 1.0),
        (const Size(540, 1190), 1.0),
        (const Size(320, 740), 2.0),
      ]) {
        tester.view.physicalSize = size;
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(SimpleDiscoverApi()),
            sessionProvider.overrideWith(SignedIn.new),
          ],
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: RepaintBoundary(key: boundary, child: const HiyallApp()),
            ),
          ),
        );
        container.read(routerProvider).go('/discover');
        for (final dark in [true, false]) {
          container.read(themeProvider.notifier).toggle(dark);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture(
            tester,
            boundary,
            'people-${size.width.toInt()}-${scale.toInt()}-${dark ? 'dark' : 'light'}',
          );
          expect(find.text('Ari').first.hitTestable(), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      }
    },
  );
}
