import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:hiyall/features/chat_starters.dart';
import 'package:hiyall/features/chat_thread.dart';
import 'package:hiyall/features/live_sync.dart';
import 'package:hiyall/shared/chat_tokens.dart';

import 'avatar_helpers.dart' show pngBytes;
import 'chat_photo_helpers.dart';
import 'chat_ui_test.dart' show UiCloud, UiEngine, fixedNow, msg, when;
import 'widget_test.dart' show FakeApi, SignedIn;

class _Images extends ChatImages {
  final ui.Image base;
  _Images(this.base);
  @override
  Future<ui.Image> decodeJpeg(
    Uint8List bytes, {
    required int w,
    required int h,
    required int targetWidth,
  }) async => base.clone();
  @override
  Future<ui.Image> decodePixels(PreviewPixels p) async => base.clone();
}

/// Records what was sent instead of encrypting it.
class SpyEngine extends UiEngine {
  SpyEngine(super.cloud);
  final sent = <String>[];
  @override
  Future<void> send(String conversationId, String peerId, String text) async {
    sent.add(text);
  }
}

void main() {
  late UiCloud cloud;
  late SpyEngine engine;
  late FakeApi api;
  late ui.Image base;

  void spec(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, (tester) async {
        cloud = UiCloud();
        engine = SpyEngine(cloud);
        api = FakeApi();
        await body(tester);
      });

  /// The real app (router, shell) at the conversation, so "Block" can leave it.
  Future<void> open(
    WidgetTester tester, {
    List<ChatMessage> messages = const [],
    Object? shared = const <String>[],
    bool omitShared = false,
    String name = 'Niko',
    Size size = const Size(390, 844),
    double textScale = 1,
    bool dark = true,
    bool still = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    base = (await tester.runAsync(() => decodeImageFromList(pngBytes)))!;
    engine.messages = [...messages];
    cloud.receipt = {if (!omitShared) 'sharedInterests': shared};
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        chatEngineProvider.overrideWith((ref) async => engine),
        sessionProvider.overrideWith(SignedIn.new),
        chatImagesProvider.overrideWithValue(_Images(base)),
        chatClockProvider.overrideWithValue(() => fixedNow),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            disableAnimations: still,
            textScaler: TextScaler.linear(textScale),
          ),
          child: const HiyallApp(),
        ),
      ),
    );
    container.read(themeProvider.notifier).toggle(dark);
    container
        .read(routerProvider)
        .go('/chats/$conv?peer=$peerId&name=${Uri.encodeQueryComponent(name)}');
    await tester.pumpAndSettle();
  }

  List<String> chipTexts(WidgetTester tester) => [
    for (final w in tester.widgetList<Wrap>(
      find.byKey(const Key('new-chat-starters')),
    ))
      for (final c in w.children)
        c.key.toString().replaceAll(RegExp(r"^\[<'starter-|'>\]$"), ''),
  ];

  String composer(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('chat-input')))
      .controller!
      .text;

  group('the new-chat card', () {
    spec('without shared interests: the name, a plain prompt, general chips', (
      tester,
    ) async {
      await open(tester);
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
      expect(find.text('Say hi to Niko 👋'), findsOneWidget);
      expect(find.byKey(const Key('new-chat-shared')), findsNothing);
      expect(find.textContaining('You both'), findsNothing);
      expect(find.text('Pick an idea or write your own.'), findsOneWidget);
      final expected = startersFor(conv, const []);
      expect(expected.length, 4);
      for (final s in expected) {
        expect(find.byKey(Key('starter-$s')), findsOneWidget, reason: s);
      }
    });

    spec('with one shared interest: a genuine line and chips about it', (
      tester,
    ) async {
      await open(tester, shared: const ['Music']);
      expect(find.text('You both love Music 🎧'), findsOneWidget);
      expect(find.text('Pick an idea or write your own.'), findsNothing);
      final expected = startersFor(conv, const ['Music']);
      expect(expected.length, 3);
      for (final s in expected) {
        expect(find.byKey(Key('starter-$s')), findsOneWidget, reason: s);
      }
      // The first two are about music.
      final music = topicFor('Music')!.starters;
      expect(music.contains(expected[0]), isTrue);
      expect(music.contains(expected[1]), isTrue);
    });

    spec('with two: one line naming both', (tester) async {
      await open(tester, shared: const ['Gaming', 'Music', 'Art']);
      expect(find.text('You both like Gaming 🎮 and Music 🎧'), findsOneWidget);
      expect(find.textContaining('Art'), findsNothing);
    });

    spec('a custom interest is said as typed', (tester) async {
      await open(tester, shared: const ['Skateboarding']);
      expect(find.text('You both like Skateboarding'), findsOneWidget);
      for (final s in startersFor(conv, const ['Skateboarding'])) {
        expect(find.byKey(Key('starter-$s')), findsOneWidget);
      }
    });

    spec('a missing, null or malformed sharedInterests is just no line', (
      tester,
    ) async {
      for (final value in <Object?>[null, 'Music', 7, const []]) {
        await open(tester, shared: value);
        expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
        expect(find.byKey(const Key('new-chat-shared')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      await open(tester, omitShared: true);
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
      expect(find.byKey(const Key('new-chat-shared')), findsNothing);
    });

    spec('the same chat shows the same chips every time', (tester) async {
      await open(tester, shared: const ['Travel']);
      final first = chipTexts(tester);
      expect(first, isNotEmpty);
      await tester.pumpWidget(const SizedBox());
      await open(tester, shared: const ['Travel']);
      expect(chipTexts(tester), first);
    });

    spec('a chip only fills the composer; nothing is sent', (tester) async {
      await open(tester, shared: const ['Music']);
      final chip = startersFor(conv, const ['Music']).first;
      await tester.tap(find.byKey(Key('starter-$chip')));
      await tester.pump();
      expect(composer(tester), chip);
      expect(engine.sent, isEmpty);
      // Still there, and the person can edit before sending.
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('chat-input')), '$chip :)');
      await tester.pump();
      expect(engine.sent, isEmpty);
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(engine.sent, ['$chip :)']);
    });

    spec('it never blocks sending: type and send with the card up', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('chat-input')),
        'hello there',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(engine.sent, ['hello there']);
    });

    spec('Dismiss leaves the quiet chip and the composer', (tester) async {
      await open(tester, shared: const ['Music']);
      await tester.tap(find.byKey(const Key('new-chat-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation-empty')), findsNothing);
      expect(find.byKey(const Key('conversation-empty-quiet')), findsOneWidget);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    });

    spec('it goes away once there is a message', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
      engine.messages = [msg('a', 'hi!', when(10, 0))];
      engine.ctrl.add(conv);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation-empty')), findsNothing);
      expect(find.byKey(const Key('conversation-empty-quiet')), findsNothing);
      expect(find.text('hi!'), findsOneWidget);
    });

    spec('it is not shown to a chat that already has messages', (tester) async {
      await open(
        tester,
        messages: [msg('a', 'hi', when(10, 0))],
        shared: const ['Music'],
      );
      expect(find.byKey(const Key('conversation-empty')), findsNothing);
      expect(find.textContaining('You both'), findsNothing);
    });

    spec('the safety line says "in control" and has Report and Block', (
      tester,
    ) async {
      await open(tester);
      expect(
        find.text('You’re in control: report or block anytime'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('new-chat-report')), findsOneWidget);
      expect(find.byKey(const Key('new-chat-block')), findsOneWidget);
      for (final key in ['new-chat-report', 'new-chat-block']) {
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(44),
          reason: key,
        );
      }
    });

    spec('Report opens the same report sheet as the menu', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('new-chat-report')));
      await tester.pumpAndSettle();
      expect(find.text('Report this chat'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Report this chat'), findsNothing);
      // The menu route to the very same sheet.
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-report')));
      await tester.pumpAndSettle();
      expect(find.text('Report this chat'), findsOneWidget);
    });

    spec('Block asks first, then blocks and leaves the chat', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('new-chat-block')));
      await tester.pumpAndSettle();
      expect(find.text('Block Niko?'), findsOneWidget);
      expect(api.requestedBlock, isNull);
      // Cancelling blocks nobody.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.requestedBlock, isNull);
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('new-chat-block')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-block')));
      await tester.pumpAndSettle();
      expect(api.requestedBlock, isTrue);
      expect(find.byKey(const Key('conversation-empty')), findsNothing);
    });

    spec('the menu has the same Block, through the same handler', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-block')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-block')));
      await tester.pumpAndSettle();
      expect(find.text('Block Niko?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-block')));
      await tester.pumpAndSettle();
      expect(api.requestedBlock, isTrue);
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      for (final shared in [
        const <String>[],
        const ['Travel', 'Photography'],
      ]) {
        spec('fits 320 px at text x$scale, ${shared.length} shared', (
          tester,
        ) async {
          await open(
            tester,
            shared: shared,
            name: 'Alexandrina Montgomery-Featherstonehaugh',
            size: const Size(320, 568),
            textScale: scale,
            dark: false,
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('new-chat-safety')), findsOneWidget);
          // The card scrolls when it must, and the composer stays reachable.
          expect(find.byKey(const Key('chat-input')), findsOneWidget);
        });
      }
    }

    spec('stays small at normal text size', (tester) async {
      await open(tester, shared: const ['Music', 'Gaming']);
      final height = tester.getSize(
        find.byKey(const Key('conversation-empty')),
      );
      expect(height.height, lessThan(844 * .62));
    });
  });

  group('the header', () {
    spec('name 20 px bold on one line, subtitle kept, 56 px tall', (
      tester,
    ) async {
      await open(tester, messages: [msg('a', 'hi', when(10, 0))]);
      final name = tester.widget<Text>(
        find.byKey(const Key('chat-header-name')),
      );
      expect(name.style!.fontSize, 20);
      expect(name.style!.fontWeight, FontWeight.w700);
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(find.text('end-to-end encrypted'), findsOneWidget);
      expect(tester.getSize(find.byType(ChatHeader)).height, 56);
    });

    spec('the shield is a 48 dp control labelled Safety and encryption', (
      tester,
    ) async {
      await open(tester, messages: [msg('a', 'hi', when(10, 0))]);
      final shield = find.byKey(const Key('safety-number-button'));
      final size = tester.getSize(shield);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Safety and encryption'), findsWidgets);
      handle.dispose();
      // The tooltip says the same, and the tap opens the safety number.
      expect(find.byTooltip('Safety and encryption'), findsOneWidget);
      await tester.tap(shield);
      await tester.pumpAndSettle();
      expect(find.text('Verify safety number'), findsOneWidget);
    });

    for (final (width, scale) in [
      (320.0, 1.0),
      (320.0, 1.3),
      (320.0, 2.0),
      (390.0, 2.0),
    ]) {
      spec('does not overflow at ${width.toInt()} px, text x$scale', (
        tester,
      ) async {
        await open(
          tester,
          messages: [msg('a', 'hi', when(10, 0))],
          name: 'Alexandrina Montgomery-Featherstonehaugh',
          size: Size(width, 640),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        // The header keeps its height whatever the text size.
        expect(tester.getSize(find.byType(ChatHeader)).height, 56);
        final name = tester.getRect(find.byKey(const Key('chat-header-name')));
        final shield = tester.getRect(
          find.byKey(const Key('safety-number-button')),
        );
        final more = tester.getRect(find.byKey(const Key('chat-options')));
        expect(name.right, lessThanOrEqualTo(shield.left + .5));
        expect(shield.right, lessThanOrEqualTo(more.left + .5));
        expect(more.right, lessThanOrEqualTo(width));
      });
    }

    spec('a muted chat still fits at 320 px', (tester) async {
      cloud.receipt = {};
      await open(
        tester,
        messages: [msg('a', 'hi', when(10, 0))],
        name: 'Alexandrina Montgomery-Featherstonehaugh',
        size: const Size(320, 640),
        textScale: 2,
      );
      cloud.receipt = {
        'mutedUntil': DateTime.now()
            .add(const Duration(days: 1))
            .toIso8601String(),
      };
      engine.ctrl.add(conv);
      ProviderScope.containerOf(tester.element(find.byType(ConversationScreen)))
          .read(chatSignalProvider.notifier)
          .bump();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-muted')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('bubbles', () {
    spec('a one-word message is a pill, not a box', (tester) async {
      await open(tester, messages: [msg('a', 'ok', when(10, 0))]);
      final bubble = tester.getSize(
        find
            .ancestor(of: find.text('ok'), matching: find.byType(DecoratedBox))
            .first,
      );
      // About one line of text plus padding: its corners (22) are half its height or more.
      expect(
        bubble.height,
        lessThanOrEqualTo(2 * ChatMetrics.bubbleRadius + 2),
      );
      expect(bubble.height, greaterThanOrEqualTo(36));
    });

    spec('run spacing: tight inside a run, a little air between runs', (
      tester,
    ) async {
      await open(
        tester,
        messages: [
          msg('a', 'one', when(10, 0)),
          msg('b', 'two', when(10, 1)),
          msg('c', 'three', when(10, 2), mine: true),
          msg('d', 'four', when(10, 3), mine: true),
        ],
      );
      Rect rect(String text) => tester.getRect(
        find
            .ancestor(of: find.text(text), matching: find.byType(DecoratedBox))
            .first,
      );
      final insideTheirs = rect('two').top - rect('one').bottom;
      final insideMine = rect('four').top - rect('three').bottom;
      final between = rect('three').top - rect('two').bottom;
      expect(insideTheirs, closeTo(ChatMetrics.bubbleGap, .6));
      expect(insideMine, closeTo(ChatMetrics.bubbleGap, .6));
      expect(between, closeTo(ChatMetrics.runGap, .6));
      expect(ChatMetrics.bubbleGap, inInclusiveRange(2, 3));
      expect(ChatMetrics.runGap, inInclusiveRange(10, 12));
    });

    test('the geometry constants are the designed ones', () {
      expect(ChatMetrics.bubbleRadius, inInclusiveRange(22, 24));
      expect(ChatMetrics.bubbleJoin, inInclusiveRange(6, 8));
      expect(ChatMetrics.bubbleTail, 4);
    });

    test('radii by position in a run, both sides', () {
      const big = Radius.circular(ChatMetrics.bubbleRadius);
      const join = Radius.circular(ChatMetrics.bubbleJoin);
      const tail = Radius.circular(ChatMetrics.bubbleTail);
      // Mine hug the right edge: the right side is the near side.
      final single = bubbleRadii(mine: true, first: true, last: true);
      expect(
        [single.topLeft, single.bottomLeft, single.topRight],
        [big, big, big],
      );
      expect(single.bottomRight, tail);
      final first = bubbleRadii(mine: true, first: true, last: false);
      expect([first.topRight, first.bottomRight], [big, join]);
      final middle = bubbleRadii(mine: true, first: false, last: false);
      expect([middle.topRight, middle.bottomRight], [join, join]);
      expect([middle.topLeft, middle.bottomLeft], [big, big]);
      final last = bubbleRadii(mine: true, first: false, last: true);
      expect([last.topRight, last.bottomRight], [join, tail]);
      // Theirs are the mirror image.
      final theirsLast = bubbleRadii(mine: false, first: false, last: true);
      expect([theirsLast.topLeft, theirsLast.bottomLeft], [join, tail]);
      expect([theirsLast.topRight, theirsLast.bottomRight], [big, big]);
      final theirsFirst = bubbleRadii(mine: false, first: true, last: false);
      expect([theirsFirst.topLeft, theirsFirst.bottomLeft], [big, join]);
    });
  });

  group('send motion', () {
    Future<void> pumpEntrance(
      WidgetTester tester, {
      required bool mine,
      bool still = false,
      bool animate = true,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: Scaffold(
            body: BubbleEntrance(
              mine: mine,
              animate: animate,
              child: const SizedBox(key: Key('child'), width: 100, height: 40),
            ),
          ),
        ),
      ),
    );

    double opacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find.ancestor(
            of: find.byKey(const Key('child')),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;

    testWidgets('your bubble slides up and fades in within 160 to 220 ms', (
      tester,
    ) async {
      expect(
        BubbleEntrance.duration.inMilliseconds,
        inInclusiveRange(160, 220),
      );
      await pumpEntrance(tester, mine: true);
      final start = tester.getTopLeft(find.byKey(const Key('child')));
      expect(opacity(tester), lessThan(.2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacity(tester), inExclusiveRange(.2, 1));
      await tester.pump(BubbleEntrance.duration);
      expect(opacity(tester), 1);
      // It started lower than where it ended up.
      final settled = tester.getTopLeft(find.byKey(const Key('child')));
      expect(start.dy, greaterThan(settled.dy + 8));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('theirs settle in a shorter way', (tester) async {
      expect(BubbleEntrance.rise(false), lessThan(BubbleEntrance.rise(true)));
      await pumpEntrance(tester, mine: false);
      await tester.pump(BubbleEntrance.duration);
      expect(opacity(tester), 1);
    });

    testWidgets('reduced motion: there at once, nothing runs', (tester) async {
      await pumpEntrance(tester, mine: true, still: true);
      expect(opacity(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a bubble that has played does not play again', (tester) async {
      await pumpEntrance(tester, mine: true, animate: false);
      expect(opacity(tester), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    spec('sending is never held back by the motion', (tester) async {
      await open(tester, still: false);
      await tester.enterText(find.byKey(const Key('chat-input')), 'go');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      // One frame is enough for the engine to have it.
      await tester.pump();
      expect(engine.sent, ['go']);
      await tester.pumpAndSettle();
    });

    spec('the send button dips a little under the thumb', (tester) async {
      expect(ChatComposer.sendPressScale, inInclusiveRange(.8, .95));
      await open(tester, still: false);
      await tester.enterText(find.byKey(const Key('chat-input')), 'go');
      await tester.pump();
      final press = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('chat-send'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final scales = tester
          .widgetList<AnimatedScale>(
            find.descendant(
              of: find.byKey(const Key('chat-send')),
              matching: find.byType(AnimatedScale),
            ),
          )
          .map((s) => s.scale);
      expect(scales, contains(ChatComposer.sendPressScale));
      await press.up();
      await tester.pumpAndSettle();
    });
  });

  group('the delivery mark', () {
    Widget mark(SendStatus status, {bool still = false, bool seen = false}) =>
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: still),
            child: Scaffold(
              body: StatusMark(status: status, seen: seen, color: Colors.black),
            ),
          ),
        );

    testWidgets('fades from the clock to the tick', (tester) async {
      await tester.pumpWidget(mark(SendStatus.sending));
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      await tester.pumpWidget(mark(SendStatus.sent));
      await tester.pump(const Duration(milliseconds: 60));
      // Mid-fade: both are there.
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.schedule_rounded), findsNothing);
      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    });

    testWidgets('instant with reduced motion', (tester) async {
      await tester.pumpWidget(mark(SendStatus.sending, still: true));
      await tester.pumpWidget(mark(SendStatus.sent, still: true));
      await tester.pump();
      expect(find.byIcon(Icons.schedule_rounded), findsNothing);
      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    });
  });

  group('typing indicator', () {
    test('a soft wave through the three dots, then a rest', () {
      // Every dot rises from nothing, peaks and falls back; never negative.
      for (var i = 0; i < 3; i++) {
        var peak = 0.0;
        for (var ms = 0; ms <= 1600; ms += 10) {
          final w = typingWave(ms / 1600, i);
          expect(w, inInclusiveRange(0, 1));
          if (w > peak) peak = w;
        }
        expect(peak, closeTo(1, .01), reason: 'dot $i');
        expect(typingWave(0, i), i == 0 ? 0 : 0);
      }
      // Staggered: when the first dot peaks the others are lower.
      final t = 280 / 1600;
      expect(typingWave(t, 0), greaterThan(typingWave(t, 1)));
      expect(typingWave(t, 1), greaterThan(typingWave(t, 2)));
      // The last part of the breath is rest: all three at zero.
      for (var i = 0; i < 3; i++) {
        expect(typingWave(.9, i), 0);
        expect(typingWave(.99, i), 0);
      }
      // No jump anywhere: neighbouring 10 ms samples differ by a little.
      for (var i = 0; i < 3; i++) {
        for (var ms = 0; ms < 1600; ms += 10) {
          expect(
            (typingWave((ms + 10) / 1600, i) - typingWave(ms / 1600, i)).abs(),
            lessThan(.2),
          );
        }
      }
    });

    spec('animates with motion on, holds still with reduced motion', (
      tester,
    ) async {
      await open(tester, messages: [msg('a', 'hi', when(10, 0))], still: false);
      final c = ProviderScope.containerOf(
        tester.element(find.byType(ConversationScreen)),
      );
      c.read(typingProvider.notifier).mark(conv);
      await tester.pump();
      expect(find.byKey(const Key('typing-bubble')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.hasRunningAnimations, isTrue);
      c.read(typingProvider.notifier).clear(conv);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
