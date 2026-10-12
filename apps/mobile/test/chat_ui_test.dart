import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_list.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:hiyall/features/chat_starters.dart';
import 'package:hiyall/features/chat_thread.dart';
import 'package:hiyall/features/live_sync.dart';

import 'avatar_helpers.dart' show pngBytes;
import 'chat_photo_helpers.dart';
import 'widget_test.dart' show SignedIn;

class UiCloud extends FakeCloud {
  Map<String, dynamic> receipt = {};
  @override
  Future<Map<String, dynamic>> conversation(String id) async => receipt;
  @override
  Future<int> unreadMessages() async => 0;
}

class UiEngine extends ChatEngine {
  UiEngine(this.cloud)
    : super(
        userId: meId,
        api: cloud,
        store: MemoryChatStore(),
        codec: FakeCodec(),
      );
  final UiCloud cloud;
  List<ChatMessage> messages = [];
  List<ChatConversation> list = [];
  final ctrl = StreamController<String>.broadcast();
  @override
  Stream<String> get changes => ctrl.stream;
  @override
  Future<List<ChatMessage>> history(String conversationId) async => messages;
  @override
  Future<List<ChatConversation>> conversations({int limit = 50}) async => list;
  @override
  Future<void> pollNow() async {}
  @override
  Future<void> markRead(String conversationId) async {}
}

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

final fixedNow = DateTime(2026, 10, 12, 15, 30);
DateTime when(int h, int m, {int daysAgo = 0}) =>
    DateTime(2026, 10, 12 - daysAgo, h, m);

ChatMessage msg(
  String id,
  String text,
  DateTime at, {
  bool mine = false,
  SendStatus status = SendStatus.sent,
  ChatAttachment? att,
  bool notice = false,
}) => ChatMessage(
  messageId: id,
  senderId: mine ? meId : peerId,
  text: att != null ? photoFallbackText : text,
  sentAt: at,
  serverAt: status == SendStatus.sent && !notice ? at.toUtc() : null,
  mine: mine,
  notice: notice,
  attachment: att,
  status: status,
);

ChatAttachment photo({String caption = ''}) {
  final d = descriptor();
  d['caption'] = caption;
  return ChatAttachment.parse(d);
}

ChatConversation chat(
  int n,
  String name,
  String username,
  ChatMessage? last, {
  int unread = 0,
  bool muted = false,
  bool online = false,
  DateTime? lastSeenAt,
}) => ChatConversation(
  '00000000-0000-4000-8000-0000000000${(n + 10).toString().padLeft(2, '0')}',
  '019a4000-0000-7000-8000-0000000001${n.toString().padLeft(2, '0')}',
  name,
  username,
  last,
  unreadCount: unread,
  mutedUntil: muted ? DateTime.now().add(const Duration(days: 1)) : null,
  online: online,
  lastSeenAt: lastSeenAt,
);

void main() {
  late UiCloud cloud;
  late UiEngine engine;
  late ui.Image base;

  Future<void> pumpApp(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
    bool still = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    base = (await tester.runAsync(() => decodeImageFromList(pngBytes)))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatEngineProvider.overrideWith((ref) async => engine),
          sessionProvider.overrideWith(SignedIn.new),
          chatImagesProvider.overrideWithValue(_Images(base)),
          chatClockProvider.overrideWithValue(() => fixedNow),
        ],
        child: MaterialApp(
          theme: hiyallTheme(dark ? Brightness.dark : Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: still,
            ),
            child: child!,
          ),
          home: Scaffold(body: screen),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openConversation(
    WidgetTester tester,
    List<ChatMessage> messages, {
    String name = 'Niko',
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
    bool still = true,
  }) async {
    engine.messages = messages;
    await pumpApp(
      tester,
      ConversationScreen(id: conv, peerId: peerId, peerName: name),
      size: size,
      dark: dark,
      textScale: textScale,
      still: still,
    );
  }

  Future<void> openList(
    WidgetTester tester,
    List<ChatConversation> list, {
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
  }) async {
    engine.list = list;
    await pumpApp(
      tester,
      const ChatsScreen(),
      size: size,
      dark: dark,
      textScale: textScale,
      still: true,
    );
  }

  void spec(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, (tester) async {
        cloud = UiCloud();
        engine = UiEngine(cloud);
        await body(tester);
      });

  group('relative times', () {
    final now = DateTime(2026, 10, 12, 15, 30);
    test('chat list time', () {
      expect(
        chatListTime(now.subtract(const Duration(seconds: 20)), now),
        'now',
      );
      expect(chatListTime(now.subtract(const Duration(minutes: 5)), now), '5m');
      expect(chatListTime(DateTime(2026, 10, 12, 13, 10), now), '2h');
      expect(chatListTime(DateTime(2026, 10, 11, 23, 50), now), 'Yesterday');
      // Sunday 11 Oct is Yesterday; Saturday 10 Oct 2026 is a Saturday.
      expect(chatListTime(DateTime(2026, 10, 10, 9), now), 'Sat');
      expect(chatListTime(DateTime(2026, 10, 6, 9), now), 'Tue');
      expect(chatListTime(DateTime(2026, 10, 5, 9), now), '5 Oct');
      expect(chatListTime(DateTime(2025, 12, 25, 9), now), '25 Dec 2025');
    });

    test('day chips', () {
      expect(chatDayLabel(DateTime(2026, 10, 12, 0, 1), now), 'Today');
      expect(chatDayLabel(DateTime(2026, 10, 11, 23, 59), now), 'Yesterday');
      expect(chatDayLabel(DateTime(2026, 10, 3, 12), now), '3 Oct');
      expect(chatDayLabel(DateTime(2024, 2, 3, 12), now), '3 Feb 2024');
    });
  });

  group('emoji only', () {
    test('one to three emoji', () {
      for (final t in [
        '👋',
        '😂😂😂',
        '❤️',
        '🔥 🔥',
        '🇮🇳',
        '👍🏽',
        '👨‍👩‍👧',
      ]) {
        expect(isEmojiOnly(t), isTrue, reason: t);
      }
      for (final t in ['', 'hi 👋', '😂😂😂😂', 'ok', '1', '#', '👋!']) {
        expect(isEmojiOnly(t), isFalse, reason: t);
      }
    });
  });

  group('search', () {
    final list = [
      chat(
        1,
        'Mira Kapoor',
        'mira',
        msg('a', 'bringing the speaker', when(9, 0)),
      ),
      chat(
        2,
        'Niko',
        'niko_b',
        msg('b', 'see you at 8', when(9, 0), mine: true),
      ),
      chat(3, 'Dev', 'dev', null),
    ];
    test('filters by name, username and last message', () {
      expect(filterConversations(list, '').length, 3);
      expect(filterConversations(list, 'MIR').single.peerName, 'Mira Kapoor');
      expect(filterConversations(list, '@niko').single.peerName, 'Niko');
      expect(
        filterConversations(list, 'speaker').single.peerName,
        'Mira Kapoor',
      );
      expect(filterConversations(list, 'at 8').single.peerName, 'Niko');
      expect(filterConversations(list, 'zzz'), isEmpty);
    });

    spec('typing narrows the list and shows the empty-search state', (
      tester,
    ) async {
      await openList(tester, list);
      expect(find.text('Mira Kapoor'), findsOneWidget);
      expect(find.text('Dev'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('chat-search')), 'speak');
      await tester.pump(chatSearchDebounce);
      expect(find.text('Mira Kapoor'), findsOneWidget);
      expect(find.text('Dev'), findsNothing);
      await tester.enterText(find.byKey(const Key('chat-search')), 'qqq');
      await tester.pump(chatSearchDebounce);
      expect(find.byKey(const Key('chats-no-match')), findsOneWidget);
      expect(find.text('No conversations found'), findsOneWidget);
      expect(find.textContaining('qqq'), findsWidgets);
      await tester.tap(find.byKey(const Key('chat-primary')));
      await tester.pump();
      expect(find.byKey(const Key('chats-no-match')), findsNothing);
      expect(find.text('Dev'), findsOneWidget);
    });
  });

  group('chat list', () {
    spec('rows show relative time, unread and muted badges', (tester) async {
      final recent = fixedNow.subtract(const Duration(minutes: 5));
      final a = chat(1, 'Mira', 'mira', msg('a', 'hey', recent), unread: 3);
      final b = chat(
        2,
        'Niko',
        'niko',
        msg('b', 'yo', when(9, 0, daysAgo: 1)),
        unread: 120,
        muted: true,
      );
      await openList(tester, [a, b]);
      expect(find.text('5m'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);
      expect(find.byKey(Key('muted-${b.id}')), findsOneWidget);
    });

    spec('"Chats" appears once on a phone and not at all inside a wide shell', (
      tester,
    ) async {
      await openList(tester, [chat(1, 'Mira', 'mira', null)]);
      expect(find.text('Chats'), findsOneWidget);
      await openList(tester, [
        chat(1, 'Mira', 'mira', null),
      ], size: const Size(1280, 800));
      expect(find.text('Chats'), findsNothing);
    });

    spec('the list is a centred column on a wide window', (tester) async {
      final a = chat(1, 'Mira', 'mira', msg('a', 'hey', when(9, 0)));
      await openList(tester, [a], size: const Size(1600, 900));
      final row = tester.getRect(find.byType(ChatRow));
      expect(row.width, lessThanOrEqualTo(chatListMaxWidth));
      expect(row.center.dx, closeTo(800, 1));
    });

    spec('an empty list is friendly and offers Meet someone new', (
      tester,
    ) async {
      await openList(tester, []);
      expect(find.byKey(const Key('chats-empty')), findsOneWidget);
      expect(find.text('No conversations yet'), findsWidgets);
      expect(
        find.text('Someone interesting is one hello away.'),
        findsOneWidget,
      );
      expect(find.text('Meet someone new'), findsOneWidget);
      expect(find.text('Say hi to your followers'), findsOneWidget);
      expect(find.byKey(const Key('chat-search')), findsNothing);
    });

    spec('a typing peer replaces the preview', (tester) async {
      final a = chat(1, 'Mira', 'mira', msg('a', 'hey there', when(9, 0)));
      await openList(tester, [a]);
      ProviderScope.containerOf(tester.element(find.byType(ChatsScreen)))
          .read(typingProvider.notifier)
          .mark(a.id);
      await tester.pump();
      expect(find.text('typing…'), findsOneWidget);
      expect(find.text('hey there'), findsNothing);
      ProviderScope.containerOf(tester.element(find.byType(ChatsScreen)))
          .read(typingProvider.notifier)
          .clear(a.id);
    });

    spec('text at 1.3x does not overflow', (tester) async {
      await openList(tester, [
        chat(
          1,
          'Alexandrina Montgomery-Featherstonehaugh',
          'alexandrina',
          msg(
            'a',
            'a long last message that keeps going and going',
            when(9, 0),
          ),
          unread: 12,
          muted: true,
        ),
      ], textScale: 1.3);
      expect(tester.takeException(), isNull);
    });

    spec('light theme renders', (tester) async {
      await openList(tester, [
        chat(1, 'Mira', 'mira', msg('a', 'hey', when(9, 0)), unread: 2),
      ], dark: false);
      expect(tester.takeException(), isNull);
      expect(find.text('Mira'), findsOneWidget);
    });
  });

  group('thread layout', () {
    test('groups runs, day rows and the unread divider', () {
      final rows = buildThread(
        [
          msg('1', 'a', when(9, 0, daysAgo: 1)),
          msg('2', 'b', when(9, 1)),
          msg('3', 'c', when(9, 2)),
          msg('4', 'd', when(9, 3), mine: true),
          msg('5', 'e', when(9, 30)),
          msg('6', 'f', when(9, 31)),
        ],
        unreadFrom: '5',
        typing: true,
      );
      expect(rows.map((r) => r.runtimeType.toString()).toList(), [
        'DayRow', 'MessageRow', // 1
        'DayRow', 'MessageRow', 'MessageRow', // 2, 3
        'MessageRow', // 4
        'UnreadRow', 'MessageRow', 'MessageRow', // 5, 6
        'TypingRow',
      ]);
      final messageRows = rows.whereType<MessageRow>().toList();
      expect(messageRows[1].first, isTrue);
      expect(messageRows[1].last, isFalse);
      expect(messageRows[2].last, isTrue);
      expect(messageRows[2].showAvatar, isTrue);
      expect(messageRows[3].showAvatar, isFalse);
      expect(messageRows[4].first, isTrue);
      expect(messageRows[4].last, isFalse);
      expect(messageRows[5].last, isTrue);
    });

    spec('day chips read Today, Yesterday and a date', (tester) async {
      await openConversation(tester, [
        msg('a', 'old', when(10, 0, daysAgo: 9)),
        msg('b', 'yesterday', when(10, 0, daysAgo: 1)),
        msg('c', 'today', when(10, 0)),
      ]);
      expect(find.text('3 Oct'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
    });

    spec('the peer avatar sits by the last incoming bubble of a run only', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('a', 'one', when(10, 0)),
        msg('b', 'two', when(10, 1)),
        msg('c', 'three', when(10, 2)),
        msg('d', 'mine', when(10, 3), mine: true),
        msg('e', 'four', when(10, 4)),
      ]);
      expect(find.byKey(const Key('peer-avatar-a')), findsNothing);
      expect(find.byKey(const Key('peer-avatar-b')), findsNothing);
      expect(find.byKey(const Key('peer-avatar-c')), findsOneWidget);
      expect(find.byKey(const Key('peer-avatar-d')), findsNothing);
      expect(find.byKey(const Key('peer-avatar-e')), findsOneWidget);
    });

    spec('"New messages" marks the first unread message', (tester) async {
      cloud.receipt = {'unreadCount': 2};
      await openConversation(tester, [
        msg('a', 'old', when(10, 0)),
        msg('b', 'mine', when(10, 5), mine: true),
        msg('c', 'new one', when(10, 10)),
        msg('d', 'new two', when(10, 11)),
      ]);
      expect(find.byKey(const Key('new-messages')), findsOneWidget);
      final divider = tester
          .getTopLeft(find.byKey(const Key('new-messages')))
          .dy;
      expect(divider, lessThan(tester.getTopLeft(find.text('new one')).dy));
      expect(divider, greaterThan(tester.getTopLeft(find.text('mine')).dy));
    });

    spec('no divider when nothing was unread', (tester) async {
      await openConversation(tester, [msg('a', 'old', when(10, 0))]);
      expect(find.byKey(const Key('new-messages')), findsNothing);
    });

    spec('the conversation is a centred column on a wide window', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('a', 'hello there', when(10, 0)),
        msg('b', 'hi!', when(10, 1), mine: true),
      ], size: const Size(1600, 900));
      final mine = tester.getRect(find.text('hi!'));
      expect(mine.right, lessThanOrEqualTo(800 + conversationMaxWidth / 2));
      final input = tester.getRect(find.byKey(const Key('chat-input')));
      expect(input.right, lessThanOrEqualTo(800 + conversationMaxWidth / 2));
      expect(tester.getRect(find.byType(ChatHeader)).width, 1600);
      expect(find.text('Chats'), findsNothing);
    });

    spec('text at 1.3x does not overflow', (tester) async {
      await openConversation(
        tester,
        [
          msg(
            'a',
            'a fairly long message that has to wrap onto several lines at this scale',
            when(10, 0),
          ),
          msg(
            'b',
            'and a reply that is just as long and also wraps over lines',
            when(10, 1),
            mine: true,
          ),
        ],
        name: 'Alexandrina Montgomery-Featherstonehaugh',
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
    });

    spec('light theme renders', (tester) async {
      await openConversation(tester, [
        msg('a', 'hi', when(10, 0)),
        msg('b', 'hey', when(10, 1), mine: true),
      ], dark: false);
      expect(tester.takeException(), isNull);
      expect(find.text('hey'), findsOneWidget);
    });
  });

  group('header', () {
    spec('a long name stays on one line and the header keeps its height', (
      tester,
    ) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      final short = tester.getSize(find.byType(ChatHeader)).height;
      await openConversation(
        tester,
        [msg('a', 'hi', when(10, 0))],
        name: 'Alexandrina Montgomery-Featherstonehaugh the Third of Her Name',
      );
      final long = tester.getSize(find.byType(ChatHeader)).height;
      expect(long, short);
      final name = tester.widget<Text>(
        find.byKey(const Key('chat-header-name')),
      );
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(
        tester.getSize(find.byKey(const Key('chat-header-name'))).height,
        lessThan(30),
      );
    });

    spec('typing swaps the subtitle without moving anything', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      expect(find.text('end-to-end encrypted'), findsOneWidget);
      final before = tester.getSize(find.byType(ChatHeader));
      final nameAt = tester.getTopLeft(
        find.byKey(const Key('chat-header-name')),
      );
      final c = ProviderScope.containerOf(
        tester.element(find.byType(ConversationScreen)),
      );
      c.read(typingProvider.notifier).mark(conv);
      await tester.pump();
      expect(find.text('typing…'), findsOneWidget);
      expect(find.text('end-to-end encrypted'), findsNothing);
      expect(tester.getSize(find.byType(ChatHeader)), before);
      expect(
        tester.getTopLeft(find.byKey(const Key('chat-header-name'))),
        nameAt,
      );
      expect(
        tester.getSize(find.byKey(const Key('chat-header-subtitle'))).height,
        18,
      );
      c.read(typingProvider.notifier).clear(conv);
    });

    spec(
      'typing shows three dots in a bubble, held still when motion is reduced',
      (tester) async {
        await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
        expect(find.byKey(const Key('typing-bubble')), findsNothing);
        final c = ProviderScope.containerOf(
          tester.element(find.byType(ConversationScreen)),
        );
        c.read(typingProvider.notifier).mark(conv);
        await tester.pump();
        expect(find.byKey(const Key('typing-bubble')), findsOneWidget);
        final h = tester.ensureSemantics();
        expect(find.bySemanticsLabel('Niko is typing'), findsOneWidget);
        h.dispose();
        // Reduced motion: nothing keeps animating, so the tree settles.
        await tester.pumpAndSettle(
          const Duration(milliseconds: 50),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 1),
        );
        c.read(typingProvider.notifier).clear(conv);
        await tester.pump();
        expect(find.byKey(const Key('typing-bubble')), findsNothing);
      },
    );

    spec('with motion on the dots animate', (tester) async {
      await openConversation(tester, [
        msg('a', 'hi', when(10, 0)),
      ], still: false);
      final c = ProviderScope.containerOf(
        tester.element(find.byType(ConversationScreen)),
      );
      c.read(typingProvider.notifier).mark(conv);
      await tester.pump();
      final first = tester.getTopLeft(
        find
            .descendant(
              of: find.byKey(const Key('typing-bubble')),
              matching: find.byType(Container),
            )
            .last,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.hasRunningAnimations, isTrue);
      expect(first, isNotNull);
      c.read(typingProvider.notifier).clear(conv);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('bubbles', () {
    spec('a captioned photo hugs its content instead of stretching', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('p1', '', when(10, 0), att: photo(caption: 'golden hour')),
      ]);
      final photoRect = tester.getRect(find.byKey(const Key('photo-p1')));
      final bubble = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const Key('photo-p1')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      // The photo plus its 4 px frame, nothing wider.
      expect(bubble.width, closeTo(photoRect.width + 8, .5));
      expect(bubble.width, lessThan(390 * .8));
      final caption = tester.getTopLeft(
        find.byKey(const Key('photo-caption-p1')),
      );
      expect(caption.dx, closeTo(photoRect.left + 8, .5));
      expect(
        tester.getRect(find.byKey(const Key('photo-caption-p1'))).width,
        lessThanOrEqualTo(photoRect.width),
      );
    });

    spec('a photo without a caption is only as wide as the photo', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('p1', '', when(10, 0), att: photo()),
      ]);
      final photoRect = tester.getRect(find.byKey(const Key('photo-p1')));
      final bubble = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const Key('photo-p1')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(bubble.width, closeTo(photoRect.width + 8, .5));
    });

    spec('one to three emoji are large with no bubble', (tester) async {
      await openConversation(tester, [
        msg('e1', '🔥🔥', when(10, 0)),
        msg('t1', 'plain text', when(10, 5)),
      ]);
      final emoji = tester.widget<Text>(find.byKey(const Key('emoji-e1')));
      expect(emoji.style!.fontSize, greaterThanOrEqualTo(38));
      expect(
        find.ancestor(
          of: find.byKey(const Key('emoji-e1')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).borderRadius != null,
          ),
        ),
        findsNothing,
      );
      // Ordinary text keeps its bubble.
      expect(
        find.ancestor(
          of: find.text('plain text'),
          matching: find.byType(DecoratedBox),
        ),
        findsWidgets,
      );
      expect(find.byKey(const Key('emoji-t1')), findsNothing);
    });

    spec('a text bubble is as wide as its text, not the maximum', (
      tester,
    ) async {
      await openConversation(tester, [msg('a', 'hey', when(10, 0))]);
      final bubble = tester.getRect(
        find
            .ancestor(of: find.text('hey'), matching: find.byType(DecoratedBox))
            .first,
      );
      expect(bubble.width, lessThan(200));
    });

    spec(
      'incoming bubbles are tinted and bordered; outgoing is a lime gradient',
      (tester) async {
        await openConversation(tester, [
          msg('a', 'theirs', when(10, 0)),
          msg('b', 'mine', when(10, 1), mine: true),
        ]);
        DecoratedBox box(String text) => tester.widget<DecoratedBox>(
          find
              .ancestor(
                of: find.text(text),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final theirs = box('theirs').decoration as BoxDecoration;
        final mine = box('mine').decoration as BoxDecoration;
        expect(theirs.border, isNotNull);
        expect(
          theirs.color,
          isNot(
            Theme.of(tester.element(find.text('theirs')))
                .scaffoldBackgroundColor,
          ),
        );
        expect(mine.gradient, isA<LinearGradient>());
      },
    );
  });

  group('status', () {
    spec('sent, seen, sending and not sent get their marks and spoken text', (
      tester,
    ) async {
      cloud.receipt = {
        'peerReadAt': when(
          10,
          1,
        ).toUtc().add(const Duration(minutes: 1)).toIso8601String(),
      };
      final h = tester.ensureSemantics();
      await openConversation(tester, [
        msg('a', 'read one', when(10, 0), mine: true),
        msg('b', 'unread one', when(10, 50), mine: true),
        msg(
          'c',
          'in flight',
          when(11, 5),
          mine: true,
          status: SendStatus.sending,
        ),
        msg('d', 'broken', when(11, 6), mine: true, status: SendStatus.failed),
      ]);
      expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);
      expect(find.text('Not sent'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^You, .*, seen: read one')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^You, .*, sent: unread one')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^You, .*, sending: in flight')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^You, .*, not sent: broken')),
        findsOneWidget,
      );
      h.dispose();
    });

    spec('incoming messages say who and when', (tester) async {
      final h = tester.ensureSemantics();
      await openConversation(tester, [msg('a', 'hello', when(10, 0))]);
      expect(
        find.bySemanticsLabel(RegExp(r'^Niko, .*: hello')),
        findsOneWidget,
      );
      h.dispose();
    });

    spec('only the newest outgoing message carries the seen key', (
      tester,
    ) async {
      cloud.receipt = {'peerReadAt': when(12, 0).toUtc().toIso8601String()};
      await openConversation(tester, [
        msg('a', 'first', when(10, 0), mine: true),
        msg('b', 'second', when(10, 30), mine: true),
      ]);
      expect(find.byKey(const Key('seen')), findsOneWidget);
    });
  });

  group('composer', () {
    spec('shows every line of a multi-line draft up to six, then scrolls', (
      tester,
    ) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      final one = tester.getSize(find.byKey(const Key('chat-input'))).height;
      await tester.enterText(find.byKey(const Key('chat-input')), 'a\nb\nc\nd');
      await tester.pump();
      final four = tester.getSize(find.byKey(const Key('chat-input'))).height;
      expect(four, greaterThan(one + 2 * 15));
      final lineHeight = (four - one) / 3;
      await tester.enterText(
        find.byKey(const Key('chat-input')),
        List.generate(12, (i) => 'line $i').join('\n'),
      );
      await tester.pump();
      final many = tester.getSize(find.byKey(const Key('chat-input'))).height;
      expect(many, closeTo(one + 5 * lineHeight, 3));
    });

    spec('the send button wakes up when there is text', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      Color fill() {
        final box = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byKey(const Key('chat-send')),
            matching: find.byType(AnimatedContainer),
          ),
        );
        return (box.decoration as BoxDecoration).color!;
      }

      expect(fill(), isNot(VibeColors.lime));
      await tester.enterText(find.byKey(const Key('chat-input')), 'hello');
      await tester.pump();
      expect(fill(), VibeColors.lime);
    });

    spec('whitespace alone is not sendable', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      await tester.enterText(find.byKey(const Key('chat-input')), '   ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')), warnIfMissed: false);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        '   ',
      );
    });

    spec('controls keep a 48 dp target', (tester) async {
      await openConversation(tester, [msg('a', 'hi', when(10, 0))]);
      for (final key in [
        'chat-send',
        'chat-attach',
        'chat-options',
        'safety-number-button',
      ]) {
        final size = tester.getSize(find.byKey(Key(key)));
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
    });
  });

  group('empty conversation', () {
    spec('says hi, offers starters that fill the composer and a safety line', (
      tester,
    ) async {
      await openConversation(tester, []);
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
      expect(find.textContaining('Say hi'), findsOneWidget);
      expect(
        find.text('You’re in control: report or block anytime'),
        findsOneWidget,
      );
      final starters = startersFor(conv, const []);
      for (final s in starters) {
        expect(find.text(s), findsOneWidget);
      }
      await tester.tap(find.text(starters.first));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        starters.first,
      );
      // Nothing was sent for them.
      expect(find.byKey(const Key('conversation-empty')), findsOneWidget);
    });

    spec('the empty state fits a short screen with the keyboard up', (
      tester,
    ) async {
      await openConversation(tester, [], size: const Size(360, 420));
      expect(tester.takeException(), isNull);
    });
  });

  group('motion', () {
    spec('new messages pop in; history does not; reduced motion skips it', (
      tester,
    ) async {
      await openConversation(tester, [
        msg('a', 'history', when(10, 0)),
      ], still: false);
      expect(find.byKey(const ValueKey('enter-a')), findsNothing);
      engine.messages = [
        ...engine.messages,
        msg('b', 'brand new', when(10, 1)),
      ];
      engine.ctrl.add(conv);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final opacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byKey(const ValueKey('enter-b')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, lessThan(1));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Opacity>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('enter-b')),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        1,
      );
    });

    spec('with reduced motion a new message is simply there', (tester) async {
      await openConversation(tester, [msg('a', 'history', when(10, 0))]);
      engine.messages = [
        ...engine.messages,
        msg('b', 'brand new', when(10, 1)),
      ];
      engine.ctrl.add(conv);
      await tester.pump();
      await tester.pump();
      final opacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byKey(const ValueKey('enter-b')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, 1);
    });
  });

  group('contrast', () {
    spec('timestamps are at least 11 px', (tester) async {
      await openConversation(tester, [
        msg('a', 'hi', when(10, 0)),
        msg('b', 'yo', when(10, 1), mine: true),
      ]);
      final sizes = [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          if (t.data != null && RegExp(r'^\d{1,2}:\d{2}').hasMatch(t.data!))
            t.style!.fontSize!,
      ];
      expect(sizes, isNotEmpty);
      expect(sizes.every((s) => s >= 11), isTrue);
    });
  });
}
