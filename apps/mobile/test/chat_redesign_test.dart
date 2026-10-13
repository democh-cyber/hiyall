import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_list.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:hiyall/features/chat_starters.dart';
import 'package:hiyall/features/chat_thread.dart';
import 'package:hiyall/shared/avatar_gradient.dart';
import 'package:hiyall/shared/chat_tokens.dart';
import 'package:hiyall/shared/navigation_dock.dart';
import 'package:hiyall/shared/person_avatar.dart';
import 'package:hiyall/shared/press_scale.dart';

import 'avatar_helpers.dart' show pngBytes;
import 'chat_photo_helpers.dart';
import 'chat_ui_test.dart'
    show UiCloud, UiEngine, chat, fixedNow, msg, photo, when;
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
  Future<void> send(
    String conversationId,
    String peerId,
    String text, {
    ChatMessage? replyTo,
  }) async {
    sent.add(text);
  }
}

void main() {
  late UiCloud cloud;
  late SpyEngine engine;
  late ui.Image base;

  void spec(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, (tester) async {
        cloud = UiCloud();
        engine = SpyEngine(cloud);
        await body(tester);
      });

  List<Override> overrides() => [
    chatEngineProvider.overrideWith((ref) async => engine),
    sessionProvider.overrideWith(SignedIn.new),
    chatImagesProvider.overrideWithValue(_Images(base)),
    chatClockProvider.overrideWithValue(() => fixedNow),
  ];

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    base = (await tester.runAsync(() => decodeImageFromList(pngBytes)))!;
  }

  /// A screen on its own, no router. For anything that does not navigate.
  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
    bool still = true,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) async {
    await setSize(tester, size);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: hiyallTheme(dark ? Brightness.dark : Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: still,
              viewInsets: viewInsets,
            ),
            child: child!,
          ),
          home: Scaffold(body: screen),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openList(
    WidgetTester tester,
    List<ChatConversation> list, {
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
    bool still = true,
  }) async {
    engine.list = list;
    await pumpScreen(
      tester,
      const ChatsScreen(),
      size: size,
      dark: dark,
      textScale: textScale,
      still: still,
    );
  }

  Future<void> openConversation(
    WidgetTester tester,
    List<ChatMessage> messages, {
    String name = 'Niko',
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
    bool still = true,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) async {
    engine.messages = messages;
    await pumpScreen(
      tester,
      ConversationScreen(id: conv, peerId: peerId, peerName: name),
      size: size,
      dark: dark,
      textScale: textScale,
      still: still,
      viewInsets: viewInsets,
    );
  }

  /// The real app (router, shell and dock) at [route].
  Future<GoRouter> openApp(
    WidgetTester tester,
    String route, {
    Size size = const Size(390, 844),
  }) async {
    await setSize(tester, size);
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(FakeApi()), ...overrides()],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: true),
          child: const HiyallApp(),
        ),
      ),
    );
    final router = container.read(routerProvider);
    router.go(route);
    await tester.pumpAndSettle();
    return router;
  }

  final list = [
    chat(
      1,
      'Mira Kapoor',
      'mira',
      msg('a', 'bringing the speaker', when(9, 0)),
      unread: 3,
    ),
    chat(2, 'Niko', 'niko_b', msg('b', 'see you at 8', when(8, 0), mine: true)),
    chat(3, 'Dev', 'dev', msg('c', 'nice', when(7, 0)), unread: 120),
    chat(4, 'Zoya', 'zoya', null),
  ];

  // ----------------------------------------------------------- pure logic

  group('preview mapping', () {
    ChatPreview of(ChatMessage? m) => previewFor(m, username: 'niko');

    test('text, your own text, photo and the handle before any message', () {
      final text = of(msg('a', 'hello there', when(9, 0)));
      expect(text.kind, ChatPreviewKind.text);
      expect(text.line, 'hello there');
      expect(
        of(msg('b', 'on my way', when(9, 0), mine: true)).line,
        'You: on my way',
      );
      expect(of(null).line, '@niko');
      expect(of(null).kind, ChatPreviewKind.none);
    });

    test('photos read Photo, or their caption', () {
      final bare = of(msg('p', '', when(9, 0), att: photo()));
      expect(bare.kind, ChatPreviewKind.photo);
      expect(bare.line, 'Photo');
      final captioned = of(
        msg(
          'q',
          '',
          when(9, 0),
          att: photo(caption: 'golden hour'),
          mine: true,
        ),
      );
      expect(captioned.isPhoto, isTrue);
      expect(captioned.line, 'You: golden hour');
    });

    test(
      'a message that failed says so; a blank one falls back to Message',
      () {
        final failed = of(
          msg('f', 'x', when(9, 0), mine: true, status: SendStatus.failed),
        );
        expect(failed.isFailed, isTrue);
        expect(failed.text, 'Not sent');
        expect(failed.mine, isTrue);
        expect(of(msg('e', '   ', when(9, 0))).line, 'Message');
        expect(of(msg('e2', '', when(9, 0), mine: true)).line, 'You: Message');
      },
    );

    test('a notice is shown as itself, never as "You:"', () {
      final n = of(msg('n', 'Keys changed', when(9, 0), notice: true));
      expect(n.kind, ChatPreviewKind.notice);
      expect(n.mine, isFalse);
      expect(n.line, 'Keys changed');
    });

    test('the list helper keeps its old name', () {
      expect(chatPreviewText(list[1]), 'You: see you at 8');
    });
  });

  group('list logic', () {
    test('the subtitle is computed from the conversations', () {
      expect(chatsSubtitle(null), isNull);
      expect(chatsSubtitle([]), 'No conversations yet');
      expect(chatsSubtitle([list[1], list[3]]), 'All caught up');
      expect(chatsSubtitle([list[0], list[1]]), '1 unread chat');
      expect(chatsSubtitle(list), '2 unread chats');
    });

    test('badges cap at 99+', () {
      expect(badgeCount(1), '1');
      expect(badgeCount(99), '99');
      expect(badgeCount(100), '99+');
      expect(badgeCount(4000), '99+');
    });

    test('filters combine text and unread', () {
      expect(filterChats(list).length, 4);
      expect(filterChats(list, filter: ChatFilter.unread).length, 2);
      expect(
        filterChats(
          list,
          query: 'mira',
          filter: ChatFilter.unread,
        ).single.peerName,
        'Mira Kapoor',
      );
      expect(
        filterChats(list, query: 'niko', filter: ChatFilter.unread),
        isEmpty,
      );
    });
  });

  group('scroll decisions', () {
    test(
      'auto-scroll only on first load, near the bottom, or after sending',
      () {
        expect(
          shouldAutoScroll(
            firstLoad: true,
            nearBottom: false,
            sentNewOwnMessage: false,
          ),
          isTrue,
        );
        expect(
          shouldAutoScroll(
            firstLoad: false,
            nearBottom: true,
            sentNewOwnMessage: false,
          ),
          isTrue,
        );
        expect(
          shouldAutoScroll(
            firstLoad: false,
            nearBottom: false,
            sentNewOwnMessage: true,
          ),
          isTrue,
        );
        // Reading older messages while something arrives or a tick changes.
        expect(
          shouldAutoScroll(
            firstLoad: false,
            nearBottom: false,
            sentNewOwnMessage: false,
          ),
          isFalse,
        );
      },
    );

    test('near the bottom means within the slack', () {
      expect(isNearBottom(pixels: 1000, maxExtent: 1000), isTrue);
      expect(isNearBottom(pixels: 850, maxExtent: 1000), isTrue);
      expect(isNearBottom(pixels: 800, maxExtent: 1000), isFalse);
      expect(isNearBottom(pixels: 0, maxExtent: 0), isTrue);
    });

    test(
      'bubble corners: tail on the last bubble of a run, on its own side',
      () {
        final mineLast = bubbleRadii(mine: true, first: false, last: true);
        const big = Radius.circular(ChatMetrics.bubbleRadius);
        const join = Radius.circular(ChatMetrics.bubbleJoin);
        const tail = Radius.circular(ChatMetrics.bubbleTail);
        expect(mineLast.bottomRight, tail);
        expect(mineLast.topRight, join);
        expect(mineLast.topLeft, big);
        expect(mineLast.bottomLeft, big);
        final theirsOnly = bubbleRadii(mine: false, first: true, last: true);
        expect(theirsOnly.bottomLeft, tail);
        expect(theirsOnly.topLeft, big);
        expect(theirsOnly.bottomRight, big);
        final middle = bubbleRadii(mine: true, first: false, last: false);
        expect(middle.topRight, join);
        expect(middle.bottomRight, join);
        final first = bubbleRadii(mine: true, first: true, last: false);
        expect(first.topRight, big);
        expect(first.bottomRight, join);
      },
    );
  });

  // ------------------------------------------------------------ chats list

  group('chat list', () {
    spec('rows are flat: no border, a hairline under all but the last', (
      tester,
    ) async {
      await openList(tester, list);
      final t = ChatTokens.dark;
      for (final c in list) {
        // The row's own boxes carry no border (the tint of an unread row aside).
        final boxes = find.descendant(
          of: find.byKey(ValueKey(c.id)),
          matching: find.byType(DecoratedBox),
        );
        for (final box in tester.widgetList<DecoratedBox>(boxes)) {
          final d = box.decoration;
          // (The invisible keyboard-focus ring is a transparent border.)
          if (d is BoxDecoration && d.shape == BoxShape.rectangle) {
            // (The hairline under the row is a bottom border; sides carry none.)
            final b = d.border;
            final sides = b is Border ? [b.top, b.left, b.right] : [];
            for (final side in sides) {
              expect(
                side.style == BorderStyle.none || side.color.a == 0,
                isTrue,
                reason: '${c.peerName} $d',
              );
            }
          }
        }
      }
      expect(find.byKey(Key('chat-divider-${list[0].id}')), findsOneWidget);
      expect(find.byKey(Key('chat-divider-${list.last.id}')), findsNothing);
      final divider = tester.widget<Divider>(
        find.byKey(Key('chat-divider-${list[0].id}')),
      );
      expect(divider.thickness, 1);
      expect(divider.color!.a, lessThan(1));
      expect(t.hairline, isNotNull);
    });

    spec('rows are 78 to 88 px tall, with a 52 px avatar', (tester) async {
      await openList(tester, [list[1]]);
      final row = tester.getSize(
        find.descendant(
          of: find.byType(ChatRow),
          matching: find.byType(PressScale),
        ),
      );
      expect(row.height, inInclusiveRange(78, 88));
      expect(
        tester.getSize(find.byType(PersonAvatar).first),
        const Size(52, 52),
      );
    });

    spec('unread rows are brighter: fill, name weight, lime time and counter', (
      tester,
    ) async {
      await openList(tester, [list[0], list[1]]);
      final t = ChatTokens.dark;
      Text name(String s) => tester.widget<Text>(find.text(s));
      expect(name('Mira Kapoor').style!.fontWeight, FontWeight.w700);
      expect(name('Niko').style!.fontWeight, FontWeight.w600);
      Color? fill(ChatConversation c) {
        final box = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byKey(ValueKey(c.id)),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        return (box.decoration as BoxDecoration).color;
      }

      expect(fill(list[0]), t.unreadRow);
      expect(fill(list[1]), Colors.transparent);
      final unreadTime = tester.widget<Text>(
        find.byKey(Key('chat-time-${list[0].id}')),
      );
      final readTime = tester.widget<Text>(
        find.byKey(Key('chat-time-${list[1].id}')),
      );
      expect(unreadTime.style!.color, t.accent);
      expect(readTime.style!.color, t.textTertiary);
      final badge = tester.widget<Container>(
        find.byKey(Key('unread-${list[0].id}')),
      );
      expect((badge.decoration as BoxDecoration).color, t.lime);
      expect(find.byKey(Key('unread-${list[1].id}')), findsNothing);
    });

    spec('counts above 99 read 99+', (tester) async {
      await openList(tester, list);
      expect(find.text('99+'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    spec('the subtitle says how many chats are unread', (tester) async {
      await openList(tester, list);
      expect(find.text('2 unread chats'), findsOneWidget);
    });

    spec('the subtitle says all caught up', (tester) async {
      await openList(tester, [list[1], list[3]]);
      expect(find.text('All caught up'), findsOneWidget);
    });

    spec('the subtitle of an empty list says so', (tester) async {
      await openList(tester, []);
      expect(find.text('No conversations yet'), findsWidgets);
    });

    spec('the same person has the same avatar colours on every screen', (
      tester,
    ) async {
      await openList(tester, [list[1]]);
      BoxDecoration gradientOf(Finder f) =>
          tester.widget<DecoratedBox>(f).decoration as BoxDecoration;
      final inList = gradientOf(
        find
            .descendant(
              of: find.byType(PersonAvatar).first,
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(inList.gradient, isA<LinearGradient>());
      expect(
        (inList.gradient! as LinearGradient).colors,
        avatarGradient(list[1].peerId).colors,
      );
    });
  });

  group('search', () {
    spec('filters 200 ms after the last keystroke, and clearing is instant', (
      tester,
    ) async {
      await openList(tester, list);
      expect(find.text('Search conversations'), findsOneWidget);
      expect(find.byKey(const Key('chat-search-clear')), findsNothing);
      await tester.enterText(find.byKey(const Key('chat-search')), 'speak');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Dev'), findsOneWidget, reason: 'still debouncing');
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('Dev'), findsNothing);
      expect(find.text('Mira Kapoor'), findsOneWidget);
      expect(find.byKey(const Key('chat-search-clear')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-search-clear')));
      await tester.pump();
      expect(find.text('Dev'), findsOneWidget);
      expect(find.byKey(const Key('chat-search-clear')), findsNothing);
    });

    spec('every keystroke restarts the wait', (tester) async {
      await openList(tester, list);
      await tester.enterText(find.byKey(const Key('chat-search')), 'sp');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.enterText(find.byKey(const Key('chat-search')), 'spe');
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Dev'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Dev'), findsNothing);
    });

    spec('focus brings a soft lime ring', (tester) async {
      await openList(tester, list, still: false);
      final t = ChatTokens.dark;
      Color? ring() =>
          ((tester
                      .widget<AnimatedContainer>(
                        find.byKey(const Key('chat-search-surface')),
                      )
                      .decoration!)
                  as BoxDecoration)
              .border!
              .top
              .color;
      expect(ring(), isNot(t.focusRing));
      await tester.tap(find.byKey(const Key('chat-search')));
      await tester.pumpAndSettle();
      expect(ring(), t.focusRing);
      expect(t.focusRing.a, lessThan(1), reason: 'a soft ring, not solid lime');
    });

    spec('the search field is 52 px high', (tester) async {
      await openList(tester, list);
      expect(
        tester.getSize(find.byKey(const Key('chat-search-surface'))).height,
        52,
      );
    });
  });

  group('filters', () {
    spec('All and Unread narrow the list, and combine with search', (
      tester,
    ) async {
      await openList(tester, list);
      expect(find.byKey(const Key('chat-filter-all')), findsOneWidget);
      expect(find.text('Unread · 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-filter-unread')));
      await tester.pumpAndSettle();
      expect(find.text('Mira Kapoor'), findsOneWidget);
      expect(find.text('Dev'), findsOneWidget);
      expect(find.text('Niko'), findsNothing);
      expect(find.text('Zoya'), findsNothing);
      await tester.enterText(find.byKey(const Key('chat-search')), 'dev');
      await tester.pump(chatSearchDebounce);
      expect(find.text('Mira Kapoor'), findsNothing);
      expect(find.text('Dev'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-filter-all')));
      await tester.pumpAndSettle();
      expect(find.text('Dev'), findsOneWidget);
      expect(find.text('Mira Kapoor'), findsNothing, reason: 'search stays');
    });

    spec('there is no Active filter: nothing presence-based is offered', (
      tester,
    ) async {
      await openList(tester, list);
      expect(find.text('Active'), findsNothing);
      expect(find.textContaining('Online'), findsNothing);
    });

    spec('an empty Unread filter says so and can be undone', (tester) async {
      await openList(tester, [list[1], list[3]]);
      await tester.tap(find.byKey(const Key('chat-filter-unread')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats-no-unread')), findsOneWidget);
      expect(find.text('No unread conversations'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-primary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats-no-unread')), findsNothing);
      expect(find.text('Niko'), findsOneWidget);
    });

    spec('no search matches says so and can clear the search', (tester) async {
      await openList(tester, list);
      await tester.enterText(find.byKey(const Key('chat-search')), 'zzzz');
      await tester.pump(chatSearchDebounce);
      expect(find.byKey(const Key('chats-no-match')), findsOneWidget);
      expect(find.text('No conversations found'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-primary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats-no-match')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-search')))
            .controller!
            .text,
        isEmpty,
      );
    });
  });

  group('meet someone new', () {
    spec('is under the search, compact, and honest', (tester) async {
      await openList(tester, list);
      expect(find.byKey(const Key('meet-card')), findsOneWidget);
      expect(find.text('Meet someone new'), findsOneWidget);
      expect(find.text('Start exploring →'), findsOneWidget);
      expect(find.textContaining('match'), findsNothing);
      expect(find.textContaining('random'), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const Key('meet-card'))).dy,
        greaterThan(
          tester.getBottomLeft(find.byKey(const Key('chat-search-surface'))).dy,
        ),
      );
      // (The test font is far wider than the real one, so text wraps more.)
      expect(
        tester.getSize(find.byKey(const Key('meet-card'))).height,
        lessThan(170),
      );
    });

    spec('hides while searching or filtering and returns after', (
      tester,
    ) async {
      await openList(tester, list);
      await tester.enterText(find.byKey(const Key('chat-search')), 'mira');
      await tester.pump(chatSearchDebounce);
      expect(find.byKey(const Key('meet-card')), findsNothing);
      await tester.tap(find.byKey(const Key('chat-search-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('meet-card')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-filter-unread')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('meet-card')), findsNothing);
      await tester.tap(find.byKey(const Key('chat-filter-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('meet-card')), findsOneWidget);
    });

    spec('opens Discover', (tester) async {
      await setSize(tester, const Size(390, 844));
      final router = GoRouter(
        initialLocation: '/chats',
        routes: [
          GoRoute(
            path: '/chats',
            builder: (_, _) => const Scaffold(body: ChatsScreen()),
          ),
          GoRoute(
            path: '/discover',
            builder: (_, _) => const Scaffold(body: Text('discover page')),
          ),
        ],
      );
      addTearDown(router.dispose);
      engine.list = list;
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(),
          child: MaterialApp.router(
            theme: hiyallTheme(Brightness.dark),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('meet-card')));
      await tester.pumpAndSettle();
      expect(find.text('discover page'), findsOneWidget);
    });

    spec('the empty list offers it as the primary action', (tester) async {
      await openList(tester, []);
      expect(find.byKey(const Key('meet-card')), findsNothing);
      expect(find.byKey(const Key('chat-search')), findsNothing);
      expect(find.byKey(const Key('chat-filter-all')), findsNothing);
      expect(find.text('Meet someone new'), findsOneWidget);
      expect(find.byKey(const Key('chat-primary')), findsOneWidget);
    });
  });

  group('states', () {
    spec('loading shows flat skeleton rows', (tester) async {
      engine.list = list;
      await setSize(tester, const Size(390, 844));
      final gate = Completer<List<ChatConversation>>();
      final slow = _SlowEngine(cloud, gate);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatEngineProvider.overrideWith((ref) async => slow),
            sessionProvider.overrideWith(SignedIn.new),
          ],
          child: MaterialApp(
            theme: hiyallTheme(Brightness.dark),
            home: const Scaffold(body: ChatsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats-loading')), findsOneWidget);
      expect(find.byKey(const Key('chat-search')), findsNothing);
      gate.complete(list);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats-loading')), findsNothing);
      expect(find.text('Mira Kapoor'), findsOneWidget);
    });
  });

  // --------------------------------------------------------- app and dock

  group('dock', () {
    spec('is on the list, gone in a conversation, back after going back', (
      tester,
    ) async {
      engine.list = list;
      engine.messages = [msg('a', 'hello', when(9, 0))];
      await openApp(tester, '/chats');
      expect(find.byType(NavigationDock), findsOneWidget);
      expect(find.byType(ChatsScreen), findsOneWidget);
      await tester.tap(find.byKey(ValueKey(list[0].id)));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(find.byType(NavigationDock), findsNothing);
      expect(find.byType(ChatHeader), findsOneWidget);
      // The app header (logo, bell, profile) is gone with it.
      expect(find.bySemanticsLabel('Open your profile'), findsNothing);
      expect(find.byTooltip('Open notifications'), findsNothing);
      // System back.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsNothing);
      expect(find.byType(ChatsScreen), findsOneWidget);
      expect(find.byType(NavigationDock), findsOneWidget);
    });

    spec('the header back button also returns to the list', (tester) async {
      engine.list = list;
      engine.messages = [msg('a', 'hello', when(9, 0))];
      final router = await openApp(
        tester,
        '/chats/$conv?peer=$peerId&name=Niko',
      );
      expect(find.byType(NavigationDock), findsNothing);
      await tester.tap(find.byTooltip('Back to chats'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/chats');
      expect(find.byType(NavigationDock), findsOneWidget);
      expect(find.byType(ChatsScreen), findsOneWidget);
    });

    spec('other tabs keep the dock', (tester) async {
      await openApp(tester, '/discover');
      expect(find.byType(NavigationDock), findsOneWidget);
      expect(AppShell.inConversation('/chats'), isFalse);
      expect(AppShell.inConversation('/chats/abc'), isTrue);
      expect(AppShell.inConversation('/discover'), isFalse);
    });

    testWidgets('keeps its five labelled tabs and lime selected pill', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: hiyallTheme(Brightness.dark),
          home: Scaffold(
            bottomNavigationBar: NavigationDock(
              selectedIndex: 1,
              onSelected: (_) {},
              profileName: 'Anjali',
              unreadChats: 120,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(NavigationDock.labels, [
        'Home',
        'Chats',
        'Discover',
        'Activity',
        'Me',
      ]);
      expect(find.text('99+'), findsOneWidget);
      final pill = tester.widget<Container>(
        find.byKey(const ValueKey('dock-pill-1')),
      );
      expect((pill.decoration as BoxDecoration).color!.a, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------- conversation

  group('header', () {
    spec('is 56 px, one subtitle line, and a long name ellipsizes', (
      tester,
    ) async {
      await openConversation(
        tester,
        [msg('a', 'hi', when(10, 0))],
        name: 'Alexandrina Montgomery-Featherstonehaugh the Third of Her Name',
        size: const Size(320, 640),
      );
      expect(tester.getSize(find.byType(ChatHeader)).height, 56);
      final name = tester.widget<Text>(
        find.byKey(const Key('chat-header-name')),
      );
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      expect(find.text('end-to-end encrypted'), findsOneWidget);
    });

    spec('without presence data: no online dot, no "Online now"', (
      tester,
    ) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      expect(find.byKey(const Key('chat-online-dot')), findsNothing);
      expect(find.textContaining('nline'), findsNothing);
      expect(find.textContaining('Matched'), findsNothing);
    });
  });

  group('atmosphere', () {
    spec('is the page colour with two faint gradients and no dots', (
      tester,
    ) async {
      await pumpScreen(tester, const ChatAtmosphere(child: SizedBox()));
      final t = ChatTokens.dark;
      final atmosphere = tester.widget<DecoratedBox>(
        find.byKey(const Key('chat-atmosphere')),
      );
      expect((atmosphere.decoration as BoxDecoration).color, t.bg);
      // Nothing is painted by hand: no CustomPaint, so no dot grid.
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-atmosphere')),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      final gradients = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byKey(const Key('chat-atmosphere')),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((b) => (b.decoration as BoxDecoration).gradient)
          .whereType<RadialGradient>()
          .toList();
      expect(gradients.length, 2);
      for (final g in gradients) {
        expect(g.colors.first.a, lessThanOrEqualTo(.09));
        expect(g.colors.last.a, 0);
      }
    });

    spec('the conversation has no dot pattern behind the messages', (
      tester,
    ) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      for (final p in tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(ConversationScreen),
          matching: find.byType(CustomPaint),
        ),
      )) {
        expect(
          p.painter.runtimeType.toString().toLowerCase(),
          isNot(contains('backdrop')),
        );
      }
    });
  });

  group('bubbles', () {
    spec('a run has a small tail corner only on its last bubble', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('a', 'one', when(10, 0), mine: true),
        msg('b', 'two', when(10, 1), mine: true),
        msg('c', 'three', when(10, 2), mine: true),
        msg('d', 'theirs', when(10, 3)),
      ]);
      BorderRadius radii(String text) =>
          (tester
                          .widget<DecoratedBox>(
                            find
                                .ancestor(
                                  of: find.text(text),
                                  matching: find.byType(DecoratedBox),
                                )
                                .first,
                          )
                          .decoration
                      as BoxDecoration)
                  .borderRadius!
              as BorderRadius;
      const big = Radius.circular(ChatMetrics.bubbleRadius);
      const join = Radius.circular(ChatMetrics.bubbleJoin);
      const tail = Radius.circular(ChatMetrics.bubbleTail);
      expect(radii('one').bottomRight, join);
      expect(radii('one').topRight, big);
      expect(radii('two').topRight, join);
      expect(radii('two').bottomRight, join);
      expect(radii('three').bottomRight, tail);
      expect(radii('three').bottomLeft, big);
      expect(radii('theirs').bottomLeft, tail);
      expect(radii('theirs').bottomRight, big);
    });

    spec('outgoing is the soft lime; incoming a raised surface, barely edged', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('a', 'theirs', when(10, 0)),
        msg('b', 'mine', when(10, 1), mine: true),
      ]);
      final t = ChatTokens.dark;
      BoxDecoration box(String text) =>
          tester
                  .widget<DecoratedBox>(
                    find
                        .ancestor(
                          of: find.text(text),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect((box('mine').gradient! as LinearGradient).colors, t.outgoing);
      expect(box('theirs').color, t.incoming);
      expect(box('theirs').border!.top.color.a, lessThan(.2));
    });

    spec('very long unbroken text wraps inside the bubble at 320 px', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('a', 'x' * 400, when(10, 0)),
        msg('b', 'y' * 400, when(10, 1), mine: true),
      ], size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      final width = tester
          .getSize(
            find
                .ancestor(
                  of: find.text('y' * 400),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .width;
      expect(width, lessThan(320));
    });
  });

  group('composer', () {
    spec('is one surface holding attach, input and send', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      final dock = find.byKey(const Key('chat-composer-dock'));
      expect(dock, findsOneWidget);
      for (final key in ['chat-attach', 'chat-input', 'chat-send']) {
        expect(
          find.descendant(of: dock, matching: find.byKey(Key(key))),
          findsOneWidget,
          reason: key,
        );
      }
      final r = tester.getRect(dock);
      expect(r.height, 56);
      expect(
        tester.getRect(find.byKey(const Key('chat-attach'))).left,
        greaterThan(r.left),
      );
      expect(
        tester.getRect(find.byKey(const Key('chat-send'))).right,
        lessThan(r.right + 1),
      );
      expect(
        tester.getRect(find.byKey(const Key('chat-attach'))).right,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const Key('chat-input'))).left + 1,
        ),
      );
      expect(find.text('Message…'), findsOneWidget);
    });

    spec('grows with the draft up to six lines, as one dock', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      final dock = find.byKey(const Key('chat-composer-dock'));
      final one = tester.getSize(dock).height;
      await tester.enterText(find.byKey(const Key('chat-input')), 'a\nb\nc');
      await tester.pump();
      final three = tester.getSize(dock).height;
      expect(three, greaterThan(one + 20));
      await tester.enterText(
        find.byKey(const Key('chat-input')),
        List.generate(20, (i) => 'line $i').join('\n'),
      );
      await tester.pump();
      final many = tester.getSize(dock).height;
      expect(many, greaterThan(three));
      expect(many, lessThan(one + 6 * 24));
      // Send stays at the bottom edge of the dock.
      expect(
        tester.getRect(find.byKey(const Key('chat-send'))).bottom,
        closeTo(tester.getRect(dock).bottom - 4, 1),
      );
    });

    spec('send works for text, not for empty or blank drafts', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      await tester.tap(find.byKey(const Key('chat-send')), warnIfMissed: false);
      await tester.pump();
      expect(engine.sent, isEmpty);
      await tester.enterText(find.byKey(const Key('chat-input')), '   \n ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')), warnIfMissed: false);
      await tester.pump();
      expect(engine.sent, isEmpty);
      await tester.enterText(find.byKey(const Key('chat-input')), ' hello ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(engine.sent, ['hello']);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        isEmpty,
      );
    });

    spec('stays above the keyboard and on screen', (tester) async {
      await openConversation(tester, [
        msg('a', 'hi', when(10, 0)),
      ], viewInsets: const EdgeInsets.only(bottom: 300));
      final dock = tester.getRect(find.byKey(const Key('chat-composer-dock')));
      expect(dock.bottom, lessThanOrEqualTo(844 - 300));
      expect(tester.takeException(), isNull);
    });
  });

  group('new chat', () {
    spec('says hi small, and can be dismissed', (tester) async {
      await openConversation(tester, []);
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
      expect(find.text('Say hi to Niko 👋'), findsOneWidget);
      // Small: well under two thirds of the screen even in the test font,
      // which is much wider than the real one (about 40% with it).
      expect(
        tester.getSize(find.byKey(const Key('conversation-empty'))).height,
        lessThan(844 * .62),
      );
      // No invented shared interests or match.
      expect(find.textContaining('both love'), findsNothing);
      expect(find.textContaining('Matched'), findsNothing);
      await tester.tap(find.byKey(const Key('new-chat-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation-empty')), findsNothing);
      expect(find.byKey(const Key('conversation-empty-quiet')), findsOneWidget);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    });

    spec('is not shown once there are messages', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      expect(find.byKey(const Key('conversation-empty')), findsNothing);
      expect(find.byKey(const Key('conversation-empty-quiet')), findsNothing);
    });

    spec('a starter fills the composer without sending', (tester) async {
      await openConversation(tester, []);
      final first = startersFor(conv, const []).first;
      await tester.tap(find.text(first));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        first,
      );
      expect(engine.sent, isEmpty);
    });
  });

  group('scroll to latest', () {
    List<ChatMessage> many([int n = 60]) => [
      for (var i = 0; i < n; i++)
        msg('m$i', 'message number $i', when(8, i % 60), mine: i.isOdd),
    ];

    ScrollController controller(WidgetTester tester) =>
        tester.widget<ListView>(find.byType(ListView)).controller!;

    spec('shows when reading older messages, counts arrivals, jumps back', (
      tester,
    ) async {
      await openConversation(tester, many(), size: const Size(390, 640));
      final c = controller(tester);
      expect(
        isNearBottom(
          pixels: c.position.pixels,
          maxExtent: c.position.maxScrollExtent,
        ),
        isTrue,
      );
      expect(find.byKey(const Key('scroll-to-latest')), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 900));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scroll-to-latest')), findsOneWidget);
      expect(find.byKey(const Key('scroll-to-latest-count')), findsNothing);
      final readingAt = c.position.pixels;

      engine.messages = [
        ...engine.messages,
        msg('n1', 'a new one', when(9, 1)),
      ];
      engine.ctrl.add(conv);
      await tester.pump();
      await tester.pump();
      expect(c.position.pixels, readingAt, reason: 'the view must not move');
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const Key('scroll-to-latest-count')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '1',
      );
      engine.messages = [
        ...engine.messages,
        msg('n2', 'and another', when(9, 2)),
      ];
      engine.ctrl.add(conv);
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const Key('scroll-to-latest-count')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '2',
      );
      expect(c.position.pixels, readingAt);

      await tester.tap(find.byKey(const Key('scroll-to-latest')));
      await tester.pumpAndSettle();
      expect(
        isNearBottom(
          pixels: c.position.pixels,
          maxExtent: c.position.maxScrollExtent,
        ),
        isTrue,
      );
      expect(find.byKey(const Key('scroll-to-latest')), findsNothing);
      expect(find.text('and another'), findsOneWidget);
    });

    spec('already at the bottom, a new message scrolls into view', (
      tester,
    ) async {
      await openConversation(tester, many(), size: const Size(390, 640));
      final c = controller(tester);
      engine.messages = [
        ...engine.messages,
        msg('n1', 'right at the bottom', when(9, 1)),
      ];
      engine.ctrl.add(conv);
      await tester.pumpAndSettle();
      expect(
        isNearBottom(
          pixels: c.position.pixels,
          maxExtent: c.position.maxScrollExtent,
        ),
        isTrue,
      );
      expect(find.text('right at the bottom'), findsOneWidget);
      expect(find.byKey(const Key('scroll-to-latest')), findsNothing);
    });

    spec('sending while scrolled up still takes you to your message', (
      tester,
    ) async {
      await openConversation(tester, many(), size: const Size(390, 640));
      final c = controller(tester);
      await tester.drag(find.byType(ListView), const Offset(0, 900));
      await tester.pumpAndSettle();
      engine.messages = [
        ...engine.messages,
        msg('mine1', 'just sent', when(9, 1), mine: true),
      ];
      engine.ctrl.add(conv);
      await tester.pumpAndSettle();
      expect(
        isNearBottom(
          pixels: c.position.pixels,
          maxExtent: c.position.maxScrollExtent,
        ),
        isTrue,
      );
    });

    spec(
      'a delivery tick while reading older messages does not move the view',
      (tester) async {
        final messages = many();
        await openConversation(tester, messages, size: const Size(390, 640));
        final c = controller(tester);
        await tester.drag(find.byType(ListView), const Offset(0, 900));
        await tester.pumpAndSettle();
        final at = c.position.pixels;
        // The same messages again (a status refresh), the last one mine.
        engine.messages = [...messages];
        engine.ctrl.add(conv);
        await tester.pumpAndSettle();
        expect(c.position.pixels, at);
      },
    );

    spec('with reduced motion the button is simply there', (tester) async {
      await openConversation(tester, many(), size: const Size(390, 640));
      await tester.drag(find.byType(ListView), const Offset(0, 900));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('scroll-to-latest')), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    });

    spec('the button has a 48 dp target and a spoken label', (tester) async {
      final h = tester.ensureSemantics();
      await openConversation(tester, many(), size: const Size(390, 640));
      await tester.drag(find.byType(ListView), const Offset(0, 900));
      await tester.pumpAndSettle();
      final size = tester.getSize(find.byKey(const Key('scroll-to-latest')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel('Scroll to latest'), findsOneWidget);
      h.dispose();
    });
  });

  group('safety menu', () {
    spec('offers only what exists: mute, profile, report', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-mute')), findsOneWidget);
      expect(find.byKey(const Key('chat-profile')), findsOneWidget);
      expect(find.byKey(const Key('chat-report')), findsOneWidget);
      expect(find.text('Mute chat'), findsOneWidget);
      expect(find.textContaining('End chat'), findsNothing);
      await tester.tap(find.byKey(const Key('chat-mute')));
      await tester.pumpAndSettle();
      expect(find.text('Mute this chat'), findsOneWidget);
    });
  });

  group('themes and sizes', () {
    for (final scale in [1.3, 2.0]) {
      spec('the list fits 320 px at text x$scale', (tester) async {
        await openList(
          tester,
          [
            chat(
              1,
              'Alexandrina Montgomery-Featherstonehaugh',
              'alexandrina',
              msg(
                'a',
                'a long last message that keeps going and going',
                when(9, 0),
              ),
              unread: 120,
              muted: true,
            ),
            list[0],
            list[1],
          ],
          size: const Size(320, 640),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('chat-filter-unread')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      spec('the empty list fits 320 px at text x$scale', (tester) async {
        await openList(
          tester,
          [],
          size: const Size(320, 640),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
      });

      spec('the conversation fits 320 px at text x$scale', (tester) async {
        await openConversation(
          tester,
          [
            msg(
              'a',
              'a fairly long message that has to wrap over several lines',
              when(10, 0),
            ),
            msg(
              'b',
              'and a reply that is just as long as the first one',
              when(10, 1),
              mine: true,
            ),
            msg(
              'c',
              '',
              when(10, 2),
              att: photo(caption: 'a caption that wraps'),
            ),
          ],
          name: 'Alexandrina Montgomery-Featherstonehaugh',
          size: const Size(320, 640),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byKey(const Key('chat-input')), 'a\nb\nc');
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      spec('the new-chat card fits 320 px at text x$scale', (tester) async {
        await openConversation(
          tester,
          [],
          name: 'Alexandrina Montgomery-Featherstonehaugh',
          size: const Size(320, 568),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
      });
    }

    spec('light theme: the list, its card and chips', (tester) async {
      await openList(tester, list, dark: false);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('meet-card')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-filter-unread')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Mira Kapoor'), findsOneWidget);
    });

    spec('light theme: the conversation and composer', (tester) async {
      await openConversation(tester, [
        msg('a', 'hi', when(10, 0)),
        msg('b', 'hey', when(10, 1), mine: true),
      ], dark: false);
      expect(tester.takeException(), isNull);
      expect(find.text('hey'), findsOneWidget);
    });

    spec('light theme: the new-chat card', (tester) async {
      await openConversation(tester, [], dark: false);
      expect(tester.takeException(), isNull);
      expect(find.text('Say hi to Niko 👋'), findsOneWidget);
    });

    spec('wide windows keep centred columns', (tester) async {
      await openConversation(tester, [
        msg('a', 'hello', when(10, 0)),
      ], size: const Size(1280, 800));
      final dock = tester.getRect(find.byKey(const Key('chat-composer-dock')));
      expect(dock.width, lessThanOrEqualTo(conversationMaxWidth));
      expect(dock.center.dx, closeTo(640, 1));
    });
  });

  group('reduced motion', () {
    spec('rows and badges settle with no running animations', (tester) async {
      await openList(tester, list, still: true);
      expect(tester.binding.transientCallbackCount, 0);
    });

    spec('with motion on, a badge pops in and then settles', (tester) async {
      await openList(tester, list, still: false);
      expect(find.text('3'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('haptics are harmless', () {
    spec('sendHaptic never throws', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => throw PlatformException(code: 'x'),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await sendHaptic();
    });
  });
}

/// An engine whose conversation list waits for a gate.
class _SlowEngine extends UiEngine {
  final Completer<List<ChatConversation>> gate;
  _SlowEngine(super.cloud, this.gate);
  @override
  Future<List<ChatConversation>> conversations({int limit = 50}) => gate.future;
}
