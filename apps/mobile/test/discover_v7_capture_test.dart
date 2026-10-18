import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show HiyallApp, routerProvider, themeProvider;
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/discovery.dart' show discoverFiltersProvider;
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/shared/person_avatar.dart';
import 'package:hiyall/shared/profile_space/profile_gallery.dart';

import 'chat_preview_test.dart' show gradientPng, palettes;
import 'discover_helpers.dart';
import 'editor_v2_test.dart' show EditorApi;
import 'sharing_visits_v2_test.dart' show SharingApi;
import 'widget_test.dart' show SignedIn;

import 'package:hiyall/features/nearby_optin.dart' show NearbyExplanation;

/// Writes 2x PNGs of the Wave 7 screens to `.runtime/discover-previews-v7/`. Skipped unless run with
/// `--dart-define=CAPTURE_DISCOVER=true`:
///
///     flutter test test/discover_v7_capture_test.dart --dart-define=CAPTURE_DISCOVER=true
const capturing = bool.fromEnvironment('CAPTURE_DISCOVER');

void main() {
  final key = GlobalKey();
  late List<MemoryImage> pics;

  setUpAll(() async {
    if (!capturing) return;
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    bool anyBoundary = false,
  }) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    Object? problem;
    while ((problem = tester.takeException()) != null) {
      debugPrint('EXCEPTION in $name: ${problem.toString().split('\n').first}');
    }
    void repaint(RenderObject r) {
      r.markNeedsPaint();
      r.visitChildren(repaint);
    }

    final target = anyBoundary
        ? tester.renderObject(find.byType(RepaintBoundary).first)
        : key.currentContext!.findRenderObject()!;
    repaint(target);
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = target as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 2);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.runtime/discover-previews-v7/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      img.dispose();
    });
    debugPrint('WROTE $name.png');
  }

  void scene(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, skip: !capturing, (tester) async {
        pics = (await tester.runAsync(
          () async => [
            for (var i = 0; i < 6; i++)
              MemoryImage(
                await gradientPng(palettes[i % palettes.length], 160, 160),
              ),
          ],
        ))!;
        final saved = PersonAvatar.imageFactory;
        PersonAvatar.imageFactory = (url, k) =>
            pics[(k.hashCode.abs() + url.length) % pics.length];
        addTearDown(() => PersonAvatar.imageFactory = saved);
        await body(tester);
      });

  List<Map<String, dynamic>> people() => [
    person(
      'mira',
      'Mira Kapoor',
      headline: 'Film photos and late night ramen',
      interests: ['Photography', 'Music', 'Travel'],
      shared: ['Music'],
      languages: [
        {'code': 'en', 'level': 4},
        {'code': 'ko', 'level': 2},
        {'code': 'hi', 'level': 6},
      ],
      personalityTags: ['curious', 'maker'],
      localTime: {'utcOffsetMinutes': 330, 'label': 'UTC+5:30'},
      online: true,
      reasons: ['interests', 'languages'],
    ),
    person(
      'arjun',
      'Arjun Rao',
      bio: 'Building tiny games on weekends',
      interests: ['Gaming', 'Food'],
      languages: [
        {'code': 'en', 'level': 5},
        {'code': 'ta', 'level': 6},
      ],
      personalityTags: ['night_owl'],
      localTime: {'utcOffsetMinutes': -240, 'label': 'UTC-4'},
      reasons: ['personality'],
    ),
    person(
      'noor',
      'Noor Haddad',
      headline: 'Coffee first',
      languages: [
        {'code': 'ar', 'level': 6},
      ],
    ),
  ];

  Future<ProviderContainer> discover(
    WidgetTester tester, {
    bool dark = true,
    Size size = const Size(390, 844),
    double scale = 1,
    DiscoverFake? api,
  }) => mountDiscover(
    tester,
    api ?? (DiscoverFake(people: people())..possible = people()),
    size: size,
    scale: scale,
    dark: dark,
    wrap: (app) => RepaintBoundary(key: key, child: app),
  );

  for (final dark in [true, false]) {
    final t = dark ? 'dark' : 'light';
    scene('discover rows $t', (tester) async {
      await discover(tester, dark: dark);
      await shoot(tester, 'discover-rows-$t');
    });
    scene('discover filters $t', (tester) async {
      final c = await discover(tester, dark: dark);
      c
          .read(discoverFiltersProvider.notifier)
          .set(
            PeopleFilters(
              languages: ['ko'],
              languageMinLevel: 4,
              personalityTags: ['maker'],
            ),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discover-filters')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('filter-min-level-4')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('filter-content')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await shoot(tester, 'discover-filters-$t');
    });
    scene('possible matches $t', (tester) async {
      await discover(tester, dark: dark);
      final chip = find.byKey(const Key('chip-possible'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await shoot(tester, 'possible-matches-$t');
    });
  }
  scene('discover 320 text 2.0', (tester) async {
    await discover(tester, size: const Size(320, 740), scale: 2);
    await shoot(tester, 'discover-rows-scale2-320');
  });

  Future<ProviderContainer> app(
    WidgetTester tester,
    dynamic api,
    String at, {
    bool dark = true,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: <Override>[
        apiProvider.overrideWithValue(api as ApiClient),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: key, child: const HiyallApp()),
      ),
    );
    container.read(themeProvider.notifier).toggle(dark);
    container.read(routerProvider).go(at);
    await tester.pumpAndSettle();
    return container;
  }

  for (final dark in [true, false]) {
    final t = dark ? 'dark' : 'light';
    scene('editor $t', (tester) async {
      final api = EditorApi()
        ..tags = ['curious', 'maker', 'foodie']
        ..languages = [
          const ProfileLanguage('en', 4),
          const ProfileLanguage('ko', 2),
        ]
        ..photosList = [
          for (final id in ['m1', 'm2', 'm3'])
            GalleryPhoto(
              id,
              'https://x/$id.jpg',
              'https://x/$id.jpg',
              800,
              600,
            ),
        ];
      await app(
        tester,
        api,
        '/profile/edit',
        dark: dark,
        size: const Size(390, 1500),
      );
      await shoot(tester, 'editor-top-$t');
      await tester.scrollUntilVisible(
        find.byKey(const Key('tag-curious')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await shoot(tester, 'editor-tags-$t');
    });
    scene('settings sharing $t', (tester) async {
      final api = SharingApi()..values['showBirthday'] = true;
      await app(
        tester,
        api,
        '/profile/settings',
        dark: dark,
        size: const Size(390, 1500),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('sharing-showLocalTime')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await shoot(tester, 'settings-sharing-$t');
    });
    scene('places visited $t', (tester) async {
      final api = SharingApi()
        ..places = [
          VisitedPerson(
            const Person('p1', 'mira', 'Mira Kapoor'),
            DateTime.now().subtract(const Duration(days: 1)),
          ),
          VisitedPerson(
            const Person('p2', 'arjun', 'Arjun Rao'),
            DateTime.now().subtract(const Duration(days: 4)),
          ),
        ];
      await app(tester, api, '/profile/places', dark: dark);
      await shoot(tester, 'places-visited-$t');
    });
  }

  for (final dark in [true, false]) {
    final t = dark ? 'dark' : 'light';
    scene('profile gallery $t', (tester) async {
      final api = SharingApi();
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    ProfileGalleryStrip(
                      photos: [
                        for (var i = 1; i <= 5; i++)
                          GalleryPhoto(
                            'm$i',
                            'https://x/$i.jpg',
                            'https://x/$i.jpg',
                            800,
                            600,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      api.hashCode;
      await shoot(tester, 'profile-gallery-strip-$t');
      await tester.tap(find.byKey(const Key('gallery-photo-1')));
      await shoot(tester, 'profile-photo-viewer-$t');
    });
  }

  // The words of the onboarding step "Find people near you" (the step itself is the same widget under a title).
  for (final minor in [false, true]) {
    for (final dark in [true, false]) {
      final t = '${minor ? 'minor' : 'adult'}-${dark ? 'dark' : 'light'}';
      scene('onboarding nearby $t', (tester) async {
        tester.view.physicalSize = const Size(390, 1500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: RepaintBoundary(
              key: key,
              child: Scaffold(
                body: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('STEP 6 OF 6'),
                        const SizedBox(height: 10),
                        Builder(
                          builder: (c) => Text(
                            'Find people near you',
                            style: Theme.of(c).textTheme.headlineMedium,
                          ),
                        ),
                        const SizedBox(height: 16),
                        NearbyExplanation(minor: minor, title: false),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () {},
                          child: const Text('Turn on Nearby'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('Not now'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await shoot(tester, 'onboarding-nearby-$t');
      });
    }
  }
}
