import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/discover_prefs.dart';
import 'package:hiyall/core/local_time.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/discovery.dart' show discoverFiltersProvider;
import 'package:hiyall/shared/coach_tip.dart';
import 'package:hiyall/shared/language_chip.dart';
import 'package:hiyall/shared/local_time_label.dart';
import 'package:hiyall/shared/profile_space/profile_details.dart';
import 'package:hiyall/shared/profile_space/profile_gallery.dart';
import 'package:hiyall/shared/tag_chip.dart';
import 'package:go_router/go_router.dart';

import 'avatar_helpers.dart';
import 'widget_test.dart' show SignedIn;

Widget host(
  Widget child, {
  ThemeMode mode = ThemeMode.light,
  TextDirection dir = TextDirection.ltr,
  double scale = 1,
  Size? size,
  List<Override> overrides = const [],
  bool reduce = false,
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    themeMode: mode,
    theme: ThemeData(brightness: Brightness.light),
    darkTheme: ThemeData(brightness: Brightness.dark),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: reduce,
      ),
      child: Directionality(textDirection: dir, child: app!),
    ),
    home: Scaffold(body: Center(child: child)),
  ),
);

void size(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('language chip', () {
    testWidgets('says the language and the level as one thing', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(const LanguageChip(language: ProfileLanguage('en', 4))),
      );
      expect(find.bySemanticsLabel('English, fluent'), findsOneWidget);
      // Nothing else is read: the meter and the visible name are folded into that one label.
      expect(find.bySemanticsLabel(RegExp(r'^English$')), findsNothing);
      handle.dispose();
    });

    test('the semantic label reads every level', () {
      expect(
        languageSemantics(const ProfileLanguage('ko', 1)),
        'Korean, just starting',
      );
      expect(
        languageSemantics(const ProfileLanguage('ko', 5)),
        'Korean, advanced',
      );
      expect(
        languageSemantics(const ProfileLanguage('ko', 6)),
        'Korean, native',
      );
    });

    testWidgets('the level meter fills as many bars as the level', (
      tester,
    ) async {
      await tester.pumpWidget(host(const LevelMeter(level: 4)));
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(LevelMeter),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(paint.size.width, greaterThan(20));
      await tester.pumpWidget(host(const LevelMeter(level: 1)));
      await tester.pumpWidget(host(const LevelMeter(level: 6)));
    });

    testWidgets('tapping is the drill-down and the target is 48 dp', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          LanguageChip(
            language: const ProfileLanguage('ja', 3),
            onTap: () => taps++,
            dense: true,
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(LanguageChip)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byType(LanguageChip));
      expect(taps, 1);
    });

    testWidgets(
      'fits 320 px wide at text scale 2.0, light and dark, both directions',
      (tester) async {
        size(tester, 320, 640);
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
            await tester.pumpWidget(
              host(
                const Wrap(
                  spacing: 8,
                  children: [
                    LanguageChip(language: ProfileLanguage('en', 4)),
                    LanguageChip(language: ProfileLanguage('hi', 6)),
                    LanguageChip(language: ProfileLanguage('ko', 2)),
                  ],
                ),
                mode: mode,
                dir: dir,
                scale: 2,
              ),
            );
            expect(tester.takeException(), isNull, reason: '$mode $dir');
          }
        }
      },
    );
  });

  group('tag chip', () {
    testWidgets('a personality tag has its label and icon, and is tappable', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        host(TagChip.personality('night_owl', onTap: () => taps++)),
      );
      expect(find.text('Night owl'), findsOneWidget);
      expect(find.byIcon(Icons.nightlight_outlined), findsOneWidget);
      await tester.tap(find.byType(TagChip));
      expect(taps, 1);
      expect(
        tester.getSize(find.byType(TagChip)).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('without a tap handler it is plain, labelled text', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(TagChip.interest('Music')));
      expect(find.bySemanticsLabel('Music'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('drill-down puts the filter on Discover and goes there', (
      tester,
    ) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Column(
                  children: [
                    TagChip.interest(
                      'Music',
                      onTap: () => openDiscoverWith(
                        context,
                        ref,
                        interestFilter('Music'),
                      ),
                    ),
                    TagChip.personality(
                      'maker',
                      onTap: () => openDiscoverWith(
                        context,
                        ref,
                        personalityFilter('maker'),
                      ),
                    ),
                    LanguageChip(
                      language: const ProfileLanguage('ko', 2),
                      onTap: () => openDiscoverWith(
                        context,
                        ref,
                        languageFilter(const ProfileLanguage('ko', 2)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/discover',
            builder: (context, state) => const Scaffold(body: Text('discover')),
          ),
        ],
      );
      late ProviderContainer container;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container = ProviderContainer(),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      addTearDown(container.dispose);
      await tester.tap(find.byType(TagChip).first);
      await tester.pumpAndSettle();
      expect(find.text('discover'), findsOneWidget);
      expect(container.read(discoverFiltersProvider).interests, ['Music']);
      router.go('/');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TagChip).last);
      await tester.pumpAndSettle();
      expect(container.read(discoverFiltersProvider).personalityTags, [
        'maker',
      ]);
      expect(container.read(discoverFiltersProvider).interests, isEmpty);
      router.go('/');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(LanguageChip));
      await tester.pumpAndSettle();
      expect(container.read(discoverFiltersProvider).languages, ['ko']);
    });
  });

  group('local time label', () {
    const info = LocalTimeInfo(330, 'UTC+5:30');
    late DateTime now;
    List<Override> clock() => [
      localTimeClockProvider.overrideWithValue(() => now),
    ];

    testWidgets('says the time there, compact and full', (tester) async {
      now = DateTime.utc(2026, 10, 18, 10, 12);
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              LocalTimeLabel(time: info),
              LocalTimeLabel(time: info, full: true),
            ],
          ),
          overrides: clock(),
        ),
      );
      expect(find.text('3:42 PM there'), findsOneWidget);
      expect(find.textContaining('It’s 3:42 PM there'), findsOneWidget);
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Local time there: 3:42 PM, UTC+5:30'),
        findsWidgets,
      );
      handle.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('ticks on the minute, and only while it is on screen', (
      tester,
    ) async {
      now = DateTime.utc(2026, 10, 18, 10, 12, 50);
      final covered = ValueNotifier(true);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<bool>(
            valueListenable: covered,
            builder: (context, on, _) => TickerMode(
              enabled: on,
              child: const LocalTimeLabel(time: info),
            ),
          ),
          overrides: clock(),
        ),
      );
      final state = tester.state(find.byType(LocalTimeLabel)) as dynamic;
      expect(state.ticking, isTrue);
      expect(find.text('3:42 PM there'), findsOneWidget);
      // Ten seconds later the minute turns and the text follows.
      now = DateTime.utc(2026, 10, 18, 10, 13, 0, 100);
      await tester.pump(const Duration(seconds: 11));
      expect(find.text('3:43 PM there'), findsOneWidget);
      // Covered (another tab): the timer is gone, nothing runs.
      covered.value = false;
      await tester.pump();
      expect(state.ticking, isFalse);
      now = DateTime.utc(2026, 10, 18, 10, 20);
      await tester.pump(const Duration(minutes: 5));
      expect(find.text('3:43 PM there'), findsOneWidget);
      // Back on screen: it reads again at once and ticks again.
      covered.value = true;
      await tester.pump();
      expect(find.text('3:50 PM there'), findsOneWidget);
      expect(state.ticking, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaves no timer behind when it goes away', (tester) async {
      now = DateTime.utc(2026, 10, 18, 10, 12);
      await tester.pumpWidget(
        host(const LocalTimeLabel(time: info), overrides: clock()),
      );
      await tester.pumpWidget(const SizedBox());
      // The test binding fails the test if a timer is still pending here.
    });

    testWidgets('fits at text scale 2.0 on 320 px, in both directions', (
      tester,
    ) async {
      now = DateTime.utc(2026, 10, 18, 10, 12);
      size(tester, 320, 640);
      for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
        await tester.pumpWidget(
          host(
            const Padding(
              padding: EdgeInsets.all(16),
              child: LocalTimeLabel(time: info, full: true),
            ),
            dir: dir,
            scale: 2,
            overrides: clock(),
          ),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('coach tip', () {
    List<Override> prefs(MemoryDiscoverPrefsStore store) => [
      discoverPrefsStoreProvider.overrideWithValue(store),
      sessionProvider.overrideWith(SignedIn.new),
    ];

    testWidgets('shows once, is dismissed for good, and is per key', (
      tester,
    ) async {
      final store = MemoryDiscoverPrefsStore();
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              CoachTip(tipKey: 'a', title: 'First tip', message: 'Hello'),
              CoachTip(tipKey: 'b', title: 'Second tip', message: 'World'),
            ],
          ),
          overrides: prefs(store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('First tip'), findsOneWidget);
      expect(find.text('Second tip'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss tip').first);
      await tester.pumpAndSettle();
      expect(find.text('First tip'), findsNothing);
      expect(find.text('Second tip'), findsOneWidget);
      expect(
        await store.dismissedTips('019a4000-0000-7000-8000-000000000001'),
        {'a'},
      );
      // A later launch: the saved choice is read and the dismissed tip never shows.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              CoachTip(tipKey: 'a', title: 'First tip', message: 'Hello'),
              CoachTip(tipKey: 'b', title: 'Second tip', message: 'World'),
            ],
          ),
          overrides: prefs(store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('First tip'), findsNothing);
      expect(find.text('Second tip'), findsOneWidget);
    });

    testWidgets('shows nothing until the saved choice has been read', (
      tester,
    ) async {
      final store = _SlowStore();
      await tester.pumpWidget(
        host(
          const CoachTip(tipKey: 'a', title: 'First tip', message: 'Hello'),
          overrides: prefs(store),
        ),
      );
      await tester.pump();
      expect(find.text('First tip'), findsNothing);
      store.release.complete();
      await tester.pumpAndSettle();
      expect(find.text('First tip'), findsOneWidget);
    });

    testWidgets('its action dismisses it and runs', (tester) async {
      var ran = 0;
      await tester.pumpWidget(
        host(
          CoachTip(
            tipKey: 'a',
            title: 'Tip',
            message: 'Try it',
            actionLabel: 'Try it now',
            onAction: () => ran++,
          ),
          overrides: prefs(MemoryDiscoverPrefsStore()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try it now'));
      await tester.pumpAndSettle();
      expect(ran, 1);
      expect(find.text('Tip'), findsNothing);
    });

    testWidgets(
      'is one labelled thing, with a 48 dp dismiss, and collapses at once with reduced motion',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          host(
            const CoachTip(
              tipKey: 'a',
              title: 'Tip title',
              message: 'Tip words',
            ),
            overrides: prefs(MemoryDiscoverPrefsStore()),
            reduce: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .getSemantics(
                find.byWidgetPredicate(
                  (w) =>
                      w is Semantics &&
                      (w.properties.label ?? '').startsWith('Tip:'),
                ),
              )
              .label,
          contains('Tip: Tip title. Tip words'),
        );
        final dismiss = find.byTooltip('Dismiss tip');
        expect(tester.getSize(dismiss).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(dismiss).width, greaterThanOrEqualTo(48));
        await tester.tap(dismiss);
        // One frame: with reduced motion there is no size animation to wait for.
        await tester.pump();
        expect(find.text('Tip title'), findsNothing);
        handle.dispose();
      },
    );

    testWidgets('fits 320 px at text scale 2.0, dark, right to left', (
      tester,
    ) async {
      size(tester, 320, 640);
      await tester.pumpWidget(
        host(
          const SingleChildScrollView(
            child: CoachTip(
              tipKey: 'a',
              title: 'People you may like',
              message: 'Picked from what you share: interests, personality and languages you can practise together.',
              actionLabel: 'See them',
            ),
          ),
          overrides: prefs(MemoryDiscoverPrefsStore()),
          mode: ThemeMode.dark,
          dir: TextDirection.rtl,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('gallery', () {
    late AvatarRequests requests;
    setUp(() => requests = AvatarRequests(() => const BrokenImage()));
    tearDown(AvatarRequests.restore);

    List<GalleryPhoto> photos(int n) => [
      for (var i = 1; i <= n; i++)
        GalleryPhoto(
          'm$i',
          'https://cdn.test/m$i/full.jpg?sig=1',
          'https://cdn.test/m$i/thumb.jpg?sig=1',
          800,
          600,
        ),
    ];

    testWidgets('the strip shows every photo, labelled "Photo 2 of 3"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(ProfileGalleryStrip(photos: photos(3))));
      for (var i = 1; i <= 3; i++) {
        expect(find.bySemanticsLabel('Photo $i of 3'), findsOneWidget);
      }
      // Thumbnails are cached by media id, never by the signed URL.
      expect(
        requests.keys,
        containsAll(['photo:m1:thumb', 'photo:m2:thumb', 'photo:m3:thumb']),
      );
      for (final k in requests.keys) {
        expect(k, isNot(contains('sig=')));
      }
      handle.dispose();
    });

    testWidgets('no photos: nothing at all', (tester) async {
      await tester.pumpWidget(host(const ProfileGalleryStrip(photos: [])));
      expect(find.byKey(const Key('profile-gallery')), findsNothing);
    });

    testWidgets(
      'a photo opens the viewer at that photo; swipe moves on; close goes back',
      (tester) async {
        size(tester, 390, 800);
        await tester.pumpWidget(host(ProfileGalleryStrip(photos: photos(4))));
        await tester.tap(find.byKey(const Key('gallery-photo-1')));
        await tester.pumpAndSettle();
        expect(find.byType(PhotoViewer), findsOneWidget);
        expect(find.text('2 / 4'), findsOneWidget);
        // Swipe left to the next photo.
        await tester.fling(
          find.byKey(const Key('photo-viewer-pages')),
          const Offset(-300, 0),
          1500,
        );
        await tester.pumpAndSettle();
        expect(find.text('3 / 4'), findsOneWidget);
        await tester.fling(
          find.byKey(const Key('photo-viewer-pages')),
          const Offset(300, 0),
          1500,
        );
        await tester.pumpAndSettle();
        expect(find.text('2 / 4'), findsOneWidget);
        await tester.tap(find.byKey(const Key('photo-viewer-close')));
        await tester.pumpAndSettle();
        expect(find.byType(PhotoViewer), findsNothing);
      },
    );

    testWidgets('right to left: the swipe follows the reading direction', (
      tester,
    ) async {
      size(tester, 390, 800);
      await tester.pumpWidget(
        host(ProfileGalleryStrip(photos: photos(3)), dir: TextDirection.rtl),
      );
      await tester.tap(find.byKey(const Key('gallery-photo-0')));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);
      // In RTL the next photo is to the right.
      await tester.fling(
        find.byKey(const Key('photo-viewer-pages')),
        const Offset(300, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
    });

    testWidgets('pinch and double tap zoom, and a zoomed photo does not page', (
      tester,
    ) async {
      size(tester, 390, 800);
      await tester.pumpWidget(host(ProfileGalleryStrip(photos: photos(3))));
      await tester.tap(find.byKey(const Key('gallery-photo-0')));
      await tester.pumpAndSettle();
      final viewer = find.byType(InteractiveViewer).first;
      double scale() => tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      expect(scale(), 1);
      // Double tap zooms in.
      final centre = tester.getCenter(viewer);
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(centre);
      await tester.pumpAndSettle();
      expect(scale(), greaterThan(1.5));
      // While zoomed, the pager is locked.
      final pager = tester.widget<PageView>(
        find.byKey(const Key('photo-viewer-pages')),
      );
      expect(pager.physics, isA<NeverScrollableScrollPhysics>());
      // Double tap again zooms out.
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(centre);
      await tester.pumpAndSettle();
      expect(scale(), 1);
      // A pinch zooms in too.
      final a = await tester.startGesture(centre - const Offset(20, 0));
      final b = await tester.startGesture(centre + const Offset(20, 0));
      await a.moveBy(const Offset(-80, 0));
      await b.moveBy(const Offset(80, 0));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(scale(), greaterThan(1.5));
    });

    testWidgets(
      'the viewer is announced photo by photo with actions, and with reduced motion just appears',
      (tester) async {
        size(tester, 390, 800);
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          host(ProfileGalleryStrip(photos: photos(3)), reduce: true),
        );
        await tester.tap(find.byKey(const Key('gallery-photo-1')));
        // One frame is enough: no transition to wait for.
        await tester.pump();
        expect(find.byType(PhotoViewer), findsOneWidget);
        expect(find.bySemanticsLabel('Photo 2 of 3'), findsWidgets);
        handle.dispose();
      },
    );

    testWidgets('fits 320 px at text scale 2.0', (tester) async {
      size(tester, 320, 600);
      await tester.pumpWidget(
        host(ProfileGalleryStrip(photos: photos(8)), scale: 2),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('gallery-photo-0')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('profile details widgets', () {
    testWidgets('languages show a chip and the level in words', (tester) async {
      await tester.pumpWidget(
        host(
          const ProfileLanguageChips(
            languages: [ProfileLanguage('en', 4), ProfileLanguage('hi', 6)],
          ),
        ),
      );
      expect(find.text('Fluent'), findsOneWidget);
      expect(find.text('Native'), findsOneWidget);
      expect(find.byType(LanguageChip), findsNWidgets(2));
    });

    testWidgets('interests in common come first and are marked in words', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          const InterestChips(
            interests: ['Art', 'Music', 'Travel'],
            shared: ['music'],
          ),
        ),
      );
      expect(find.bySemanticsLabel('Music, in common'), findsOneWidget);
      expect(find.bySemanticsLabel('Art'), findsOneWidget);
      final order = tester
          .widgetList<TagChip>(find.byType(TagChip))
          .map((c) => c.label)
          .toList();
      expect(order, ['Music', 'Art', 'Travel']);
      handle.dispose();
    });

    testWidgets('personality tags are chips with icons', (tester) async {
      await tester.pumpWidget(
        host(const PersonalityChips(tags: ['curious', 'maker', 'low_key'])),
      );
      expect(find.text('Curious'), findsOneWidget);
      expect(find.text('Low-key'), findsOneWidget);
    });

    testWidgets(
      'a fact row reads as one label and the visitors entry says visiting adds you',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          host(
            const Column(
              children: [
                ProfileFactRow(
                  icon: Icons.home_outlined,
                  label: 'From',
                  value: 'Lisbon',
                ),
                RecentVisitorsEntry(userId: 'u1'),
              ],
            ),
          ),
        );
        expect(find.bySemanticsLabel('From Lisbon'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp('Recent visitors.*show up here for 30 days'),
          ),
          findsOneWidget,
        );
        handle.dispose();
      },
    );
  });
}

/// A store whose first read waits until the test lets it go.
class _SlowStore extends MemoryDiscoverPrefsStore {
  final release = Completer<void>();
  @override
  Future<Set<String>> dismissedTips(String userId) async {
    await release.future;
    return super.dismissedTips(userId);
  }
}
