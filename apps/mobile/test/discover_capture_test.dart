import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show routerProvider;
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/say_hi_prefs.dart';
import 'package:hiyall/shared/person_avatar.dart';

import 'chat_preview_test.dart' show gradientPng, palettes;
import 'discover_helpers.dart';
import 'support/fixtures.dart';

/// Writes 2x PNGs of Discover to `.runtime/discover-previews-v5/`. Skipped
/// unless run with `--dart-define=CAPTURE_DISCOVER=true`.
const capturing = bool.fromEnvironment('CAPTURE_DISCOVER');

void main() {
  final key = GlobalKey();
  late Map<String, ImageProvider> photos;

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
    bool settle = true,
  }) async {
    settle
        ? await tester.pumpAndSettle()
        : await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    settle
        ? await tester.pumpAndSettle()
        : await tester.pump(const Duration(milliseconds: 100));
    Object? problem;
    while ((problem = tester.takeException()) != null) {
      debugPrint('EXCEPTION in $name: ${problem.toString().split('\n').first}');
    }
    void repaint(RenderObject r) {
      r.markNeedsPaint();
      r.visitChildren(repaint);
    }

    repaint(key.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 2);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.runtime/discover-previews-v5/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      img.dispose();
    });
    debugPrint('WROTE $name.png');
  }

  void scene(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, skip: !capturing, (tester) async {
        photos = (await tester.runAsync(
          () async => {
            'a': MemoryImage(await gradientPng(palettes[0], 96, 96)),
            'b': MemoryImage(await gradientPng(palettes[3], 96, 96)),
          },
        ))!;
        final saved = PersonAvatar.imageFactory;
        PersonAvatar.imageFactory = (url, k) =>
            photos[Uri.parse(url).pathSegments.last.split('.').first] ??
            MemoryImage(Uint8List(0));
        addTearDown(() => PersonAvatar.imageFactory = saved);
        await body(tester);
      });

  DiscoverFake busy({bool scripts = false}) {
    final list = busyPeople(scripts: scripts);
    list.firstWhere((p) => p['userId'] == 'mira')['avatarUrl'] =
        'https://x.test/a.png';
    list.firstWhere((p) => p['userId'] == 'ana')['avatarUrl'] =
        'https://x.test/b.png';
    return DiscoverFake(people: list);
  }

  Future<ProviderContainer> mount(
    WidgetTester tester,
    DiscoverFake api, {
    Size size = const Size(390, 844),
    double scale = 1,
    bool dark = true,
    HiLog? hi,
    MemorySayHiPrefsStore? store,
    HiClock? clock,
    Map<String, String>? peers,
  }) => mountDiscover(
    tester,
    api,
    size: size,
    scale: scale,
    dark: dark,
    hi: hi,
    clock: clock,
    peers: peers,
    sayHiStore: store ?? MemorySayHiPrefsStore(),
    wrap: (app) => RepaintBoundary(key: key, child: app),
  );

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  for (final dark in [true, false]) {
    final theme = dark ? 'dark' : 'light';
    scene('main $theme 390x844', (tester) async {
      await mount(tester, busy(), dark: dark);
      await shoot(tester, 'main-$theme-390x844');
    });
  }
  scene('small 320x640', (tester) async {
    await mount(tester, busy(), size: const Size(320, 640));
    await shoot(tester, 'small-dark-320x640');
  });
  scene('large 430x932', (tester) async {
    await mount(tester, busy(), size: const Size(430, 932));
    await shoot(tester, 'large-dark-430x932');
  });
  scene('text scale 2.0 at 320', (tester) async {
    await mount(tester, busy(), size: const Size(320, 740), scale: 2);
    await shoot(tester, 'scale2-dark-320x740');
  });
  scene('wide 1280x800', (tester) async {
    await mount(tester, busy(), size: const Size(1280, 800));
    await shoot(tester, 'wide-dark-1280x800');
  });
  scene('wide light 1280x800', (tester) async {
    await mount(tester, busy(), size: const Size(1280, 800), dark: false);
    await shoot(tester, 'wide-light-1280x800');
  });
  for (final dark in [true, false]) {
    final theme = dark ? 'dark' : 'light';
    scene('filter sheet $theme', (tester) async {
      await mount(tester, busy(), dark: dark);
      await tap(tester, find.byKey(const Key('discover-filters')));
      await tap(tester, find.byKey(const Key('filter-online')));
      final list = find.descendant(
        of: find.byKey(const Key('filter-content')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('filter-gender-woman')),
        200,
        scrollable: list,
      );
      await tap(tester, find.byKey(const Key('filter-gender-woman')));
      await tester.scrollUntilVisible(
        find.text('Music'),
        200,
        scrollable: list,
      );
      await tap(tester, find.text('Music'));
      await tester.drag(list, const Offset(0, 3000));
      await tester.pumpAndSettle();
      await shoot(tester, 'filter-sheet-$theme');
    });
  }
  scene('active filters', (tester) async {
    await mount(tester, busy());
    await tap(tester, find.byKey(const Key('discover-filters')));
    await tester.scrollUntilVisible(
      find.byKey(const Key('filter-gender-woman')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('filter-content')),
        matching: find.byType(Scrollable),
      ),
    );
    await tap(tester, find.byKey(const Key('filter-gender-woman')));
    await tap(tester, find.text('Show people'));
    await shoot(tester, 'main-active-filters-dark');
  });
  scene('online chip with results', (tester) async {
    await mount(tester, busy());
    await tap(tester, find.byKey(const Key('chip-online')));
    await shoot(tester, 'online-results-dark');
  });
  scene('online chip empty', (tester) async {
    final api = busy();
    api.people = [
      for (final p in api.people) {...p}..remove('online'),
    ];
    await mount(tester, api);
    await tap(tester, find.byKey(const Key('chip-online')));
    await shoot(tester, 'online-empty-dark');
  });
  scene('empty', (tester) async {
    final api = DiscoverFake(people: const []);
    await mount(tester, api);
    await shoot(tester, 'empty-dark');
  });
  scene('empty with filters light', (tester) async {
    final api = DiscoverFake(people: const []);
    await mount(tester, api, dark: false);
    await tap(tester, find.byKey(const Key('chip-interests')));
    await shoot(tester, 'empty-filters-light');
  });
  scene('loading', (tester) async {
    final api = busy()..hold = Completer<void>();
    await mount(tester, api);
    await shoot(tester, 'loading-dark');
    api.hold!.complete();
  });
  scene('error', (tester) async {
    final api = busy()
      ..failure = const ApiFailure(
        'Could not connect. Check your connection and retry.',
      );
    await mount(tester, api);
    await shoot(tester, 'error-dark');
    final other = busy()..failure = const ApiFailure('boom', 500);
    await mount(tester, other, dark: false);
    await shoot(tester, 'error-light');
  });
  scene('surprise nothing available', (tester) async {
    await mount(tester, DiscoverFake(people: const []));
    await tap(tester, find.byKey(const Key('surprise-cta')));
    await shoot(tester, 'surprise-nothing-dark');
  });
  scene('surprise loading', (tester) async {
    final api = busy()..hold = Completer<void>();
    await mount(tester, api);
    await tester.tap(find.byKey(const Key('surprise-cta')));
    await tester.pump();
    await shoot(tester, 'surprise-loading-dark', settle: false);
    api.hold!.complete();
    await tester.pump(const Duration(seconds: 1));
  });
  // One-tap Say hi: the states of the control, the toast, the first-time sheet.
  final looks = [
    (true, const Size(390, 844), 'dark-390x844'),
    (false, const Size(390, 844), 'light-390x844'),
    (true, const Size(320, 640), 'dark-320x640'),
    (false, const Size(320, 640), 'light-320x640'),
  ];
  MemorySayHiPrefsStore sayHiMember(HiClock clock) => MemorySayHiPrefsStore()
    ..confirmedBy.add(anjaliId)
    ..sentBy[anjaliId] = {'mira': clock.now.subtract(const Duration(hours: 2))};
  for (final (dark, size, tag) in looks) {
    scene('say hi states $tag', (tester) async {
      final clock = HiClock();
      final hi = HiLog();
      await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        hi: hi,
        clock: clock,
        store: sayHiMember(clock),
        peers: {'jules': 'c-1'},
      );
      // arjun: not accepting messages; kai: a failure that can be retried.
      final list = find.byType(Scrollable).first;
      Future<void> reveal(String id) async {
        await tester.scrollUntilVisible(
          find.byKey(Key('say-hi-$id')),
          200,
          scrollable: list,
        );
        await tester.ensureVisible(find.byKey(Key('say-hi-$id')));
        await tester.pumpAndSettle();
      }

      await reveal('arjun');
      hi.failure = const ChatFailure('MESSAGES_NOT_ALLOWED', 'no', 403);
      await tap(tester, find.byKey(const Key('say-hi-arjun')));
      await reveal('kai');
      hi.failure = const ChatFailure('NETWORK', 'offline');
      await tap(tester, find.byKey(const Key('say-hi-kai')));
      // Back to the top, then the first row just under the category chips.
      await tester.fling(list, const Offset(0, 3000), 3000);
      await tester.pumpAndSettle();
      final gap = tester.getTopLeft(find.byKey(const Key('person-mira'))).dy;
      await tester.drag(list, Offset(0, -(gap - 212)));
      await tester.pumpAndSettle();
      await shoot(tester, 'say-hi-states-$tag');
    });
    scene('hovered row $tag', (tester) async {
      await mount(tester, busy(), size: size, dark: dark);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('person-mira'))),
      );
      await tester.pumpAndSettle();
      await shoot(tester, 'row-hovered-$tag');
    });
    scene('profile with wave $tag', (tester) async {
      final container = await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        store: MemorySayHiPrefsStore()..confirmedBy.add(anjaliId),
      );
      container.read(routerProvider).go('/discover/person/mira');
      await tester.pumpAndSettle();
      await shoot(tester, 'profile-wave-$tag');
    });
    scene('profile wave sent $tag', (tester) async {
      final container = await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        hi: HiLog(),
        store: MemorySayHiPrefsStore()..confirmedBy.add(anjaliId),
      );
      container.read(routerProvider).go('/discover/person/mira');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Scaffold).last,
          matching: find.byKey(const Key('say-hi-mira')),
        ),
      );
      await tester.pump();
      await tester.pump();
      await shoot(tester, 'profile-wave-sent-$tag');
      await tester.pump(const Duration(seconds: 5));
    });
    scene('say hi sending $tag', (tester) async {
      final hi = HiLog()..sendHold = Completer<void>();
      await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        hi: hi,
        store: MemorySayHiPrefsStore()..confirmedBy.add(anjaliId),
        peers: {'jules': 'c-1'},
      );
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pump();
      await tester.pump();
      await shoot(tester, 'say-hi-sending-$tag', settle: false);
      hi.sendHold!.complete();
      await tester.pumpAndSettle();
    });
    scene('say hi sent toast $tag', (tester) async {
      await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        hi: HiLog(),
        store: MemorySayHiPrefsStore()..confirmedBy.add(anjaliId),
      );
      await tap(tester, find.byKey(const Key('say-hi-mira')));
      await shoot(tester, 'say-hi-toast-$tag');
      await tester.pump(const Duration(seconds: 3));
    });
    scene('say hi rate limited $tag', (tester) async {
      final hi = HiLog()
        ..failure = const ChatFailure(
          'QUOTA',
          'You’ve reached today’s limit for starting new chats. Try again later.',
          429,
          Duration(seconds: 3412),
        );
      await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        hi: hi,
        store: MemorySayHiPrefsStore()..confirmedBy.add(anjaliId),
      );
      await tap(tester, find.byKey(const Key('say-hi-mira')));
      await shoot(tester, 'say-hi-rate-limited-$tag');
      await tester.pump(const Duration(seconds: 61));
    });
    scene('say hi first-time sheet $tag', (tester) async {
      await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        store: MemorySayHiPrefsStore(),
      );
      await tap(tester, find.byKey(const Key('say-hi-mira')));
      await shoot(tester, 'say-hi-first-time-sheet-$tag');
    });
    scene('say hi setting up encryption $tag', (tester) async {
      final hi = HiLog()
        ..ready = false
        ..engineUp = Completer<void>();
      await mount(
        tester,
        busy(),
        size: size,
        dark: dark,
        hi: hi,
        store: MemorySayHiPrefsStore()..confirmedBy.add(anjaliId),
      );
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pump();
      await tester.pump();
      await shoot(tester, 'say-hi-setting-up-$tag', settle: false);
      hi.engineUp!.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
    });
  }
  scene('languages category', (tester) async {
    await mount(tester, busy());
    // Scroll the chip row until Languages peeks in, as a member would, then tap.
    final scroller = find.byKey(const Key('discover-chips'));
    for (var i = 0; i < 20; i++) {
      if (tester.getRect(find.byKey(const Key('chip-languages'))).left < 350) {
        break;
      }
      await tester.drag(scroller, const Offset(-60, 0));
      await tester.pumpAndSettle();
    }
    final r = tester.getRect(find.byKey(const Key('chip-languages')));
    await tester.tapAt(Offset((r.left + 390) / 2, r.center.dy));
    await tester.pumpAndSettle();
    await shoot(tester, 'languages-dark-390x844');
  });
  scene('row long-press sheet', (tester) async {
    await mount(tester, busy());
    await tester.longPress(find.byKey(const Key('person-mira')));
    await shoot(tester, 'row-menu-dark-390x844');
  });
  scene('row long-press sheet light', (tester) async {
    await mount(tester, busy(), dark: false);
    await tester.longPress(find.byKey(const Key('person-mira')));
    await shoot(tester, 'row-menu-light-390x844');
  });
  for (final width in [320.0, 390.0]) {
    scene('chips scrolled to Nearby at ${width.round()}', (tester) async {
      await mount(tester, busy(), size: Size(width, 700));
      final scroller = find.byKey(const Key('discover-chips'));
      for (var i = 0; i < 20; i++) {
        if (tester.getRect(find.byKey(const Key('chip-nearby'))).left <
            width - 40) {
          break;
        }
        await tester.drag(scroller, const Offset(-60, 0));
        await tester.pumpAndSettle();
      }
      final r = tester.getRect(find.byKey(const Key('chip-nearby')));
      await tester.tapAt(Offset((r.left + width) / 2, r.center.dy));
      await tester.pumpAndSettle();
      final after = tester.getRect(find.byKey(const Key('chip-nearby')));
      expect(after.left, greaterThanOrEqualTo(0));
      expect(after.right, lessThanOrEqualTo(width));
      await shoot(tester, 'chips-nearby-selected-dark-${width.round()}');
    });
  }
  scene('surprise card height', (tester) async {
    await mount(tester, busy());
    final h = tester.getSize(find.byKey(const Key('surprise-card'))).height;
    debugPrint('SURPRISE CARD HEIGHT 390: $h');
    expect(h, inInclusiveRange(84, 92));
    expect(
      tester.getSize(find.byKey(const Key('surprise-cta'))).height,
      greaterThanOrEqualTo(44),
    );
  });
  scene('surprise error', (tester) async {
    final api = DiscoverFake(people: const []);
    await mount(tester, api);
    api.failure = const ApiFailure('Could not connect. Check your connection.');
    await tap(tester, find.byKey(const Key('surprise-cta')));
    await shoot(tester, 'surprise-error-dark');
  });
  scene('surprise states at 320 and scale 1.3 / 2.0', (tester) async {
    for (final (scale, tag) in [(1.3, '1.3'), (2.0, '2.0')]) {
      await mount(
        tester,
        DiscoverFake(people: const []),
        size: const Size(320, 740),
        scale: scale,
      );
      await shoot(tester, 'surprise-ready-dark-320-x$tag');
      await tap(tester, find.byKey(const Key('surprise-cta')));
      await shoot(tester, 'surprise-nothing-dark-320-x$tag');
      await tester.pumpWidget(const SizedBox());
    }
  });
  scene('nearby chip', (tester) async {
    final api = busy();
    for (final (i, p) in api.people.indexed) {
      p['distanceKm'] = [1, 3, 5, 5, 10, 15, 25, 25, 50][i];
    }
    await mount(tester, api);
    await tester.ensureVisible(find.byKey(const Key('chip-nearby')));
    await tap(tester, find.byKey(const Key('chip-nearby')));
    await shoot(tester, 'nearby-dark');
  });
  // Last: it loads a system font that stands in for the phone's Arabic and
  // Japanese fallback, which replaces the Latin shapes in every scene after it.
  for (final dark in [true, false]) {
    final theme = dark ? 'dark' : 'light';
    scene('rtl and cjk $theme', (tester) async {
      final fallback = File(
        '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      );
      if (fallback.existsSync()) {
        final data = ByteData.sublistView(fallback.readAsBytesSync());
        for (final family in ['SpaceGrotesk', 'Manrope']) {
          await (FontLoader(family)..addFont(Future.value(data))).load();
        }
      }
      final api = busy(scripts: true);
      api.people = [
        ...api.people.where((p) => ['sara', 'hinata'].contains(p['userId'])),
        ...api.people.where((p) => !['sara', 'hinata'].contains(p['userId'])),
      ];
      await mount(tester, api, dark: dark);
      await shoot(tester, 'rtl-cjk-$theme-390x844');
    });
  }
}
