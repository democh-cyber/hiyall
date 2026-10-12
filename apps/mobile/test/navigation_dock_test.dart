import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/shared/navigation_dock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Manrope',
    )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
  });

  Widget host({
    required int selected,
    required ValueChanged<int> onSelected,
    double scale = 1,
    double bottom = 34,
    bool dark = true,
    bool reduced = false,
    int unread = 0,
    bool activity = false,
    DockStoryState story = DockStoryState.none,
    ImageProvider? photo,
    Key? capture,
  }) => MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(scale),
        padding: EdgeInsets.only(bottom: bottom),
        disableAnimations: reduced,
      ),
      child: RepaintBoundary(
        key: capture,
        child: Scaffold(
          backgroundColor: dark
              ? const Color(0xff151915)
              : const Color(0xfff4f5ee),
          bottomNavigationBar: NavigationDock(
            selectedIndex: selected,
            onSelected: onSelected,
            profileName: 'Anjali',
            profilePhoto: photo,
            unreadChats: unread,
            newActivity: activity,
            storyState: story,
          ),
        ),
      ),
    ),
  );

  testWidgets('Five accessible targets fit phones, safe areas and large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final semantics = tester.ensureSemantics();
    try {
      for (final width in [320.0, 390.0, 430.0]) {
        tester.view.physicalSize = Size(width, 844);
        for (final dark in [true, false]) {
          for (final scale in [1.0, 1.3, 2.0]) {
            for (final bottom in [0.0, 24.0, 34.0]) {
              for (var selected = 0; selected < 5; selected++) {
                await tester.pumpWidget(
                  host(
                    selected: selected,
                    onSelected: (_) {},
                    scale: scale,
                    dark: dark,
                    bottom: bottom,
                  ),
                );
                await tester.pumpAndSettle();
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$width / $scale / $bottom / $selected / $dark',
                );
                final items = find.byType(DockDestination);
                expect(items, findsNWidgets(5));
                for (var i = 0; i < 5; i++) {
                  final rect = tester.getRect(items.at(i));
                  expect(rect.width, greaterThanOrEqualTo(48));
                  expect(rect.height, greaterThanOrEqualTo(48));
                  expect(rect.bottom, lessThanOrEqualTo(844 - bottom - 10));
                  final node = tester.getSemantics(items.at(i));
                  expect(node.label, contains(NavigationDock.labels[i]));
                  expect(
                    node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                    isTrue,
                  );
                }
              }
            }
          }
        }
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Selection navigates once with one light haptic and settles', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          calls.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    var selected = 0;
    var navigations = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return host(
            selected: selected,
            onSelected: (index) {
              setState(() => selected = index);
              navigations++;
            },
          );
        },
      ),
    );
    await tester.tap(find.byType(DockDestination).at(0));
    await tester.pump();
    expect(navigations, 0);
    expect(calls, isEmpty);
    await tester.tap(find.byType(DockDestination).at(2));
    await tester.pump();
    expect(selected, 2);
    expect(navigations, 1);
    expect(calls, ['HapticFeedbackType.selectionClick']);
    await tester.pump(const Duration(milliseconds: 250));
    // The tap ripple can outlive the 220ms icon motion; both must finish.
    expect(await tester.pumpAndSettle(), lessThan(10));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      host(selected: 4, onSelected: (_) {}, reduced: true),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('Badges and story descriptions appear only when supplied', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(host(selected: 0, onSelected: (_) {}));
      expect(find.byKey(const ValueKey('chat-unread-badge')), findsNothing);
      expect(find.byKey(const ValueKey('activity-unread-dot')), findsNothing);
      expect(find.text('A'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(DockDestination).at(4)).label,
        isNot(contains('story')),
      );
      await tester.pumpWidget(
        host(
          selected: 4,
          onSelected: (_) {},
          unread: 3,
          activity: true,
          story: DockStoryState.unseen,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-unread-dot')), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(DockDestination).at(1)).label,
        contains('3 unread messages'),
      );
      expect(
        tester.getSemantics(find.byType(DockDestination).at(4)).label,
        contains('new story'),
      );
      await tester.pumpWidget(
        host(
          selected: 4,
          onSelected: (_) {},
          unread: 105,
          story: DockStoryState.viewed,
        ),
      );
      expect(find.text('99+'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(DockDestination).at(4)).label,
        contains('story viewed'),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'Profile photo is used with an initial fallback on load failure',
    (tester) async {
      final data = await tester.runAsync(() async {
        final picture = ui.PictureRecorder();
        Canvas(picture).drawColor(Colors.blue, BlendMode.src);
        final image = await picture.endRecording().toImage(8, 8);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes;
      });
      await tester.pumpWidget(
        host(
          selected: 4,
          onSelected: (_) {},
          photo: MemoryImage(data!.buffer.asUint8List()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('A'), findsNothing);
      await tester.pumpWidget(
        host(
          selected: 4,
          onSelected: (_) {},
          photo: const AssetImage('missing-profile-photo.png'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  if (const bool.fromEnvironment('CAPTURE_DOCK')) {
    testWidgets('Capture dock only for visual review', (tester) async {
      tester.view.physicalSize = const Size(390, 112);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      for (final dark in [true, false]) {
        for (var selected = 0; selected < 5; selected++) {
          await tester.pumpWidget(
            host(
              selected: selected,
              onSelected: (_) {},
              dark: dark,
              bottom: 24,
              capture: key,
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final img = await boundary.toImage(pixelRatio: 2);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              '../../.runtime/nav-previews/${dark ? 'dark' : 'light'}-$selected.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            img.dispose();
          });
        }
      }
    });
  }
}
