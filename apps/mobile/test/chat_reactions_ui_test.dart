import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_reactions.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:hiyall/shared/chat_tokens.dart';

import 'avatar_helpers.dart' show pngBytes;
import 'chat_photo_helpers.dart';
import 'chat_ui_test.dart' show UiCloud, UiEngine, fixedNow, photo, when;
import 'widget_test.dart' show SignedIn;

const heart = '\u2764\uFE0F';
const laugh = '\u{1F602}';
const thumbs = '\u{1F44D}';
const fire = '\u{1F525}';

String uid(int n) =>
    '6d6d0000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

/// A delivered message with a real-looking id (reactions need one).
ChatMessage msgU(
  int n,
  String text,
  DateTime at, {
  bool mine = false,
  ChatReply? reply,
  Map<String, String> reactions = const {},
  ChatAttachment? att,
  SendStatus status = SendStatus.sent,
}) => ChatMessage(
  messageId: uid(n),
  senderId: mine ? meId : peerId,
  text: att != null
      ? (att.caption.isEmpty ? photoFallbackText : att.caption)
      : text,
  sentAt: at,
  serverAt: status == SendStatus.sent ? at.toUtc() : null,
  mine: mine,
  attachment: att,
  status: status,
  reply: reply,
  reactionStates: {
    for (final e in reactions.entries)
      e.key: ReactionState(
        emoji: e.value,
        at: DateTime.utc(2026, 10, 12, 12),
        id: uid(900 + e.key.hashCode % 50),
      ),
  },
);

class ReactEngine extends UiEngine {
  ReactEngine(super.cloud);
  final reacted = <({String id, String? emoji})>[];
  final sent = <({String text, String? replyTo})>[];
  Object? failReact;
  int _tick = 0;

  @override
  Future<void> react(
    String conversationId,
    String peerId,
    String messageId,
    String? emoji,
  ) async {
    reacted.add((id: messageId, emoji: emoji));
    final failure = failReact;
    if (failure != null) {
      failReact = null;
      // As the real engine: shown, then taken back, then thrown.
      throw failure;
    }
    final i = messages.indexWhere((m) => m.messageId == messageId);
    final m = messages[i];
    messages = [...messages]
      ..[i] = m.copyWith(
        reactionStates: mergeReaction(
          m.reactionStates,
          meId,
          ReactionState(
            emoji: emoji,
            at: DateTime.utc(2026, 10, 13).add(Duration(seconds: ++_tick)),
            id: uid(2000 + _tick),
          ),
        ),
      );
    ctrl.add(conversationId);
  }

  @override
  Future<void> send(
    String conversationId,
    String peerId,
    String text, {
    ChatMessage? replyTo,
  }) async {
    sent.add((text: text, replyTo: replyTo?.messageId));
    messages = [
      ...messages,
      msgU(
        500 + sent.length,
        text,
        fixedNow,
        mine: true,
        reply: replyTo == null ? null : replyOf(replyTo, meId),
      ),
    ];
    ctrl.add(conversationId);
  }
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

void main() {
  late UiCloud cloud;
  late ReactEngine engine;
  late ui.Image base;

  Future<void> open(
    WidgetTester tester,
    List<ChatMessage> messages, {
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
    bool still = true,
    String name = 'Niko',
  }) async {
    // A fresh tree: a state left by an earlier open must not carry over.
    await tester.pumpWidget(const SizedBox());
    cloud = UiCloud();
    engine = ReactEngine(cloud)..messages = messages;
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
          home: Scaffold(
            body: ConversationScreen(id: conv, peerId: peerId, peerName: name),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final base1 = [
    msgU(1, 'are we still on for friday?', when(9, 0), mine: true),
    msgU(2, 'yes, 8 at the usual place', when(9, 2)),
  ];

  Finder bubbleText(String text) => find.text(text);
  Finder pillEmoji(String e) => find.byKey(Key('react-$e'));

  Future<void> longPress(WidgetTester tester, Finder target) async {
    await tester.longPress(target);
    await tester.pumpAndSettle();
  }

  group('the floating menu', () {
    testWidgets('long press opens six reactions, Reply and Copy', (
      tester,
    ) async {
      await open(tester, base1);
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      expect(find.byKey(const Key('reaction-pill')), findsOneWidget);
      for (final e in reactionEmojis) {
        expect(pillEmoji(e), findsOneWidget, reason: e);
      }
      expect(find.byKey(const Key('menu-reply')), findsOneWidget);
      expect(find.byKey(const Key('menu-copy')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a photo has no Copy', (tester) async {
      await open(tester, [
        msgU(1, '', when(9, 0), att: photo(caption: 'dusk')),
      ]);
      await longPress(tester, find.byKey(Key('photo-${uid(1)}')));
      expect(find.byKey(const Key('reaction-pill')), findsOneWidget);
      expect(find.byKey(const Key('menu-reply')), findsOneWidget);
      expect(find.byKey(const Key('menu-copy')), findsNothing);
    });

    testWidgets('a secondary click (desktop) opens it too', (tester) async {
      await open(tester, base1);
      await tester.tap(
        bubbleText('yes, 8 at the usual place'),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reaction-pill')), findsOneWidget);
    });

    testWidgets('picking a reaction sends it and closes the menu', (
      tester,
    ) async {
      await open(tester, base1);
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      await tester.tap(pillEmoji(laugh));
      await tester.pumpAndSettle();
      expect(engine.reacted.single, (id: uid(2), emoji: laugh));
      expect(find.byKey(const Key('reaction-pill')), findsNothing);
      // The chip is there, with no count: only one person reacted.
      expect(find.byKey(const Key('chip-$laugh')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('chip-$laugh')),
          matching: find.text('1'),
        ),
        findsNothing,
      );
    });

    testWidgets(
      'the reaction already set is marked, and picking it clears it',
      (tester) async {
        await open(tester, [
          msgU(
            2,
            'yes, 8 at the usual place',
            when(9, 2),
            reactions: {meId: heart},
          ),
        ]);
        await longPress(tester, bubbleText('yes, 8 at the usual place'));
        expect(find.bySemanticsLabel('Remove $heart reaction'), findsOneWidget);
        expect(find.bySemanticsLabel('React with $laugh'), findsOneWidget);
        await tester.tap(pillEmoji(heart));
        await tester.pumpAndSettle();
        expect(engine.reacted.single, (id: uid(2), emoji: null));
        expect(find.byKey(const Key('chip-$heart')), findsNothing);
      },
    );

    testWidgets('tapping outside dismisses it and sends nothing', (
      tester,
    ) async {
      await open(tester, base1);
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      await tester.tapAt(const Offset(20, 760));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reaction-pill')), findsNothing);
      expect(engine.reacted, isEmpty);
      expect(engine.sent, isEmpty);
    });

    testWidgets('Copy puts the text on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
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
      await open(tester, base1);
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      await tester.tap(find.byKey(const Key('menu-copy')));
      await tester.pumpAndSettle();
      expect(copied, 'yes, 8 at the usual place');
    });

    testWidgets('a notice, a failed and an unsent message have no menu', (
      tester,
    ) async {
      await open(tester, [
        msgU(
          1,
          'not sent yet',
          when(9, 0),
          mine: true,
          status: SendStatus.failed,
        ),
        msgU(2, 'delivered', when(9, 5)),
      ]);
      await longPress(tester, bubbleText('not sent yet'));
      expect(find.byKey(const Key('reaction-pill')), findsNothing);
    });

    testWidgets('a message half under the header is scrolled into view first', (
      tester,
    ) async {
      await open(tester, [
        for (var i = 0; i < 30; i++)
          msgU(10 + i, 'filler message number $i', when(9, i), mine: i.isEven),
      ]);
      final list = find.byType(ListView).last;
      final viewTop = tester.getTopLeft(list).dy;
      final target = find.text('filler message number 8');
      while (target.evaluate().isEmpty) {
        await tester.drag(list, const Offset(0, 200));
        await tester.pumpAndSettle();
      }
      // Put it half under the top edge of the thread.
      final rect = tester.getRect(target);
      await tester.drag(list, Offset(0, viewTop - rect.top - 12));
      await tester.pumpAndSettle();
      // (a drag gives up the first few pixels to the touch slop)
      final shortBy = tester.getRect(target).top - (viewTop - 12);
      if (shortBy > 0) {
        await tester.drag(list, Offset(0, -(shortBy + 20)));
        await tester.pumpAndSettle();
      }
      expect(tester.getRect(target).top, lessThan(viewTop));
      await tester.longPressAt(
        Offset(tester.getRect(target).center.dx, viewTop + 4),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reaction-pill')), findsOneWidget);
      expect(tester.getRect(target).top, greaterThanOrEqualTo(viewTop));
    });

    testWidgets('with reduced motion it is there at once', (tester) async {
      await open(tester, base1);
      await tester.longPress(bubbleText('yes, 8 at the usual place'));
      await tester.pump();
      expect(find.byKey(const Key('reaction-pill')), findsOneWidget);
    });

    testWidgets('the menu is animated when motion is allowed', (tester) async {
      await open(tester, base1, still: false);
      await tester.longPress(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(const Key('reaction-pill')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reaction-pill')), findsOneWidget);
    });
  });

  group('double tap', () {
    testWidgets('toggles a heart on a text bubble', (tester) async {
      await open(tester, base1);
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pumpAndSettle();
      expect(engine.reacted.single, (id: uid(2), emoji: heart));
      expect(find.byKey(const Key('chip-$heart')), findsOneWidget);
      // Again: the heart is taken back.
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pumpAndSettle();
      expect(engine.reacted.last, (id: uid(2), emoji: null));
      expect(find.byKey(const Key('chip-$heart')), findsNothing);
    });

    testWidgets('pops a heart, unless motion is reduced', (tester) async {
      await open(tester, base1, still: false);
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('heart-pop')), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('no pop with reduced motion', (tester) async {
      await open(tester, base1);
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('heart-pop')), findsNothing);
    });
  });

  group('chips', () {
    testWidgets('show under the bubble; the count only when both chose it', (
      tester,
    ) async {
      await open(tester, [
        msgU(1, 'one', when(9, 0), reactions: {peerId: laugh, meId: heart}),
        msgU(2, 'two', when(9, 10), reactions: {peerId: fire, meId: fire}),
        msgU(3, 'three', when(9, 20), reactions: {peerId: thumbs}),
      ]);
      // Different emoji: two chips, no counts.
      final first = find
          .ancestor(of: find.text('one'), matching: find.byType(Column))
          .first;
      expect(find.byKey(const Key('chip-$laugh')), findsOneWidget);
      expect(find.byKey(const Key('chip-$heart')), findsOneWidget);
      expect(first, findsOneWidget);
      // The same emoji from both: one chip with a 2.
      expect(
        find.descendant(
          of: find.byKey(const Key('chip-$fire')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chip-$thumbs')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('chip-$thumbs')),
          matching: find.text('1'),
        ),
        findsNothing,
      );
    });

    testWidgets('read out as who reacted with what', (tester) async {
      await open(tester, [
        msgU(1, 'one', when(9, 0), reactions: {meId: heart}),
        msgU(2, 'two', when(9, 10), reactions: {peerId: laugh}),
        msgU(3, 'three', when(9, 20), reactions: {peerId: fire, meId: fire}),
      ]);
      expect(find.bySemanticsLabel('You reacted with $heart'), findsOneWidget);
      expect(find.bySemanticsLabel('Niko reacted with $laugh'), findsOneWidget);
      expect(
        find.bySemanticsLabel('You and Niko reacted with $fire'),
        findsOneWidget,
      );
    });

    testWidgets(
      'your own chip removes your reaction; the peer\'s does nothing',
      (tester) async {
        await open(tester, [
          msgU(1, 'one', when(9, 0), reactions: {meId: heart}),
          msgU(2, 'two', when(9, 10), reactions: {peerId: laugh}),
        ]);
        await tester.tap(find.byKey(const Key('chip-$laugh')));
        await tester.pumpAndSettle();
        expect(engine.reacted, isEmpty);
        await tester.tap(find.byKey(const Key('chip-$heart')));
        await tester.pumpAndSettle();
        expect(engine.reacted.single, (id: uid(1), emoji: null));
        expect(find.byKey(const Key('chip-$heart')), findsNothing);
      },
    );

    testWidgets('your chip is highlighted, theirs is not', (tester) async {
      await open(tester, [
        msgU(1, 'one', when(9, 0), reactions: {peerId: laugh, meId: heart}),
      ]);
      final t = ChatTokens.dark;
      BoxDecoration decoration(String e) =>
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byKey(Key('chip-$e')),
                          matching: find.byWidgetPredicate(
                            (w) =>
                                w is DecoratedBox &&
                                w.decoration is BoxDecoration &&
                                (w.decoration as BoxDecoration).color != null,
                          ),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect((decoration(heart).border! as Border).top.color, t.accent);
      expect((decoration(laugh).border! as Border).top.color, isNot(t.accent));
    });

    testWidgets(
      'never overlap the time, never pass the bubble width, 48 dp tall',
      (tester) async {
        await open(
          tester,
          [
            msgU(
              1,
              'a message long enough to wrap onto a second line in a narrow window',
              when(9, 0),
              mine: true,
              reactions: {peerId: laugh, meId: heart},
            ),
            msgU(2, 'ok', when(9, 10), reactions: {peerId: fire, meId: thumbs}),
          ],
          size: const Size(320, 640),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        for (final id in [1, 2]) {
          final bubble = find.byKey(Key('chip-${id == 1 ? heart : thumbs}'));
          final rect = tester.getRect(bubble);
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(320));
        }
        // The chips row sits below the bubble's text and its time.
        final time = find.textContaining(RegExp(r'\d:\d\d')).first;
        final chips = find.byKey(const Key('reaction-chips')).first;
        expect(
          tester.getRect(chips).top,
          greaterThanOrEqualTo(tester.getRect(time).bottom),
        );
      },
    );

    testWidgets('leave the chat list preview alone', (tester) async {
      final plain = msgU(1, 'hello', when(9, 0));
      final reacted = msgU(
        1,
        'hello',
        when(9, 0),
        reactions: {meId: heart, peerId: laugh},
      );
      expect(
        previewFor(reacted, username: 'niko').line,
        previewFor(plain, username: 'niko').line,
      );
      expect(reacted.preview, 'hello');
    });
  });

  group('replying', () {
    testWidgets(
      'the menu starts a reply: the bar names who and shows the line',
      (tester) async {
        await open(tester, base1);
        await longPress(tester, bubbleText('yes, 8 at the usual place'));
        await tester.tap(find.byKey(const Key('menu-reply')));
        await tester.pumpAndSettle();
        expect(find.text('Replying to Niko'), findsOneWidget);
        expect(find.byKey(const Key('reply-bar-line')), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('reply-bar-line'))).data,
          'yes, 8 at the usual place',
        );
        expect(
          find.bySemanticsLabel('Replying to Niko: yes, 8 at the usual place'),
          findsOneWidget,
        );
      },
    );

    testWidgets('replying to yourself says You, a photo says Photo', (
      tester,
    ) async {
      await open(tester, [
        msgU(1, '', when(9, 0), mine: true, att: photo(caption: 'dusk')),
        msgU(2, 'mine', when(9, 5), mine: true),
      ]);
      await longPress(tester, find.byKey(Key('photo-${uid(1)}')));
      await tester.tap(find.byKey(const Key('menu-reply')));
      await tester.pumpAndSettle();
      expect(find.text('Replying to You'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('reply-bar-line'))).data,
        'Photo',
      );
    });

    testWidgets('the X closes it and keeps what was typed', (tester) async {
      await open(tester, base1);
      await tester.enterText(
        find.byKey(const Key('chat-input')),
        'half a thought',
      );
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      await tester.tap(find.byKey(const Key('menu-reply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reply-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-bar')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        'half a thought',
      );
    });

    testWidgets('sending carries the reply, then the bar goes', (tester) async {
      await open(tester, base1);
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      await tester.tap(find.byKey(const Key('menu-reply')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('chat-input')),
        'see you there',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(engine.sent.single, (text: 'see you there', replyTo: uid(2)));
      expect(find.byKey(const Key('reply-bar')), findsNothing);
      // The new bubble carries the quote.
      expect(find.byKey(const Key('quote-block')), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp('replying to Niko: yes, 8 at the usual place'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('swiping a bubble to the right starts a reply', (tester) async {
      await open(tester, base1);
      await tester.drag(
        bubbleText('yes, 8 at the usual place'),
        const Offset(140, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Replying to Niko'), findsOneWidget);
    });

    testWidgets('a short swipe does not, and a swipe to the left does not', (
      tester,
    ) async {
      await open(tester, base1);
      await tester.drag(
        bubbleText('yes, 8 at the usual place'),
        const Offset(30, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-bar')), findsNothing);
      await tester.drag(
        bubbleText('yes, 8 at the usual place'),
        const Offset(-150, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reply-bar')), findsNothing);
    });

    testWidgets('your own bubble can be swiped too', (tester) async {
      await open(tester, base1);
      await tester.drag(
        bubbleText('are we still on for friday?'),
        const Offset(140, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Replying to You'), findsOneWidget);
    });
  });

  group('the quote in a bubble', () {
    ChatReply re(int n, String by, String snip, {String k = 'text'}) =>
        ChatReply(id: uid(n), by: by, snippet: snip, kind: k);

    testWidgets('shows who and one line; a photo says Photo', (tester) async {
      await open(tester, [
        msgU(1, 'want to go?', when(9, 0), mine: true),
        msgU(2, '', when(9, 1), att: photo()),
        msgU(3, 'yes', when(9, 2), reply: re(1, meId, 'want to go?')),
        msgU(
          4,
          'nice shot',
          when(9, 3),
          mine: true,
          reply: re(2, peerId, '', k: 'image'),
        ),
      ]);
      expect(
        find.bySemanticsLabel(RegExp('replying to You: want to go')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('replying to Niko: Photo')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
    });

    testWidgets('the local original wins over what the sender wrote', (
      tester,
    ) async {
      await open(tester, [
        msgU(1, 'the real words', when(9, 0), mine: true),
        // The sender claims the quote was of something else, written by them.
        msgU(
          2,
          'ok',
          when(9, 1),
          reply: re(1, peerId, 'words that were never said'),
        ),
      ]);
      expect(
        find.text('the real words'),
        findsNWidgets(2),
      ); // the original and its quote
      expect(find.text('words that were never said'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('replying to You: the real words')),
        findsOneWidget,
      );
    });

    testWidgets('an original that is not loaded still shows the sent snippet', (
      tester,
    ) async {
      await open(tester, [
        msgU(2, 'ok', when(9, 1), reply: re(77, meId, 'older words')),
      ]);
      expect(find.text('older words'), findsOneWidget);
      // Tapping it does nothing and shows no error.
      await tester.tap(find.text('older words'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-highlight')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a quote lights the original, briefly', (tester) async {
      final lots = [
        msgU(1, 'where it all started', when(9, 0), mine: true),
        for (var i = 0; i < 40; i++)
          msgU(
            10 + i,
            'filler message number $i',
            when(9, 1 + i ~/ 4),
            mine: i.isEven,
          ),
        msgU(
          99,
          'about that',
          when(10, 59),
          reply: re(1, meId, 'where it all started'),
        ),
      ];
      await open(tester, lots);
      expect(find.byKey(const Key('message-highlight')), findsNothing);
      await tester.tap(find.byKey(const Key('quote-block')));
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('message-highlight')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('message-highlight')),
          matching: find.text('where it all started'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('message-highlight')), findsNothing);
    });

    testWidgets(
      'a reply never nests: the quote is of the message\'s own text',
      (tester) async {
        await open(tester, [
          msgU(1, 'first', when(9, 0), mine: true),
          msgU(2, 'second', when(9, 1), reply: re(1, meId, 'first')),
        ]);
        await longPress(tester, find.text('second'));
        await tester.tap(find.byKey(const Key('menu-reply')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const Key('reply-bar-line'))).data,
          'second',
        );
      },
    );
  });

  group('a reaction that cannot be sent', () {
    testWidgets('says so in a small notice, which retries and clears itself', (
      tester,
    ) async {
      await open(tester, base1);
      engine.failReact = const ChatFailure('NETWORK', 'offline');
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      await tester.tap(pillEmoji(thumbs));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-inline-notice')), findsOneWidget);
      expect(
        find.textContaining('Couldn’t send your reaction'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('chip-$thumbs')),
        findsNothing,
        reason: 'nothing stays stuck',
      );
      // Retry sends it for real.
      await tester.tap(find.byKey(const Key('inline-notice-retry')));
      await tester.pumpAndSettle();
      expect(engine.reacted.map((r) => r.emoji), [thumbs, thumbs]);
      expect(find.byKey(const Key('chat-inline-notice')), findsNothing);
      expect(find.byKey(const Key('chip-$thumbs')), findsOneWidget);
    });

    testWidgets('goes away by itself, and by tap', (tester) async {
      await open(tester, base1);
      engine.failReact = const ChatFailure('RATE_LIMITED', 'slow', 429);
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pumpAndSettle();
      expect(find.textContaining('reacting a lot'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(const Key('chat-inline-notice')), findsNothing);

      engine.failReact = const ChatFailure('MESSAGES_NOT_ALLOWED', 'no', 403);
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(bubbleText('yes, 8 at the usual place'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-inline-notice')), findsOneWidget);
      expect(
        find.byKey(const Key('inline-notice-retry')),
        findsNothing,
        reason: 'not transient',
      );
      await tester.tap(find.textContaining('Couldn’t send your reaction'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-inline-notice')), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('custom actions for reply and react on a message', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, base1);
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('yes, 8 at the usual place')).first,
      );
      final labels = [
        for (final id
            in node.getSemanticsData().customSemanticsActionIds ?? <int>[])
          CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(
        labels,
        containsAll(['Reply', 'React with $heart', 'Choose a reaction']),
      );
      handle.dispose();
    });

    testWidgets('targets are 48 dp: pill, tiles, cancel and chips', (
      tester,
    ) async {
      await open(tester, [
        msgU(
          2,
          'yes, 8 at the usual place',
          when(9, 2),
          reactions: {meId: heart},
        ),
      ], size: const Size(320, 640));
      await longPress(tester, bubbleText('yes, 8 at the usual place'));
      for (final e in reactionEmojis) {
        final r = tester.getRect(pillEmoji(e));
        expect(r.width, greaterThanOrEqualTo(48), reason: e);
        expect(r.height, greaterThanOrEqualTo(48), reason: e);
      }
      expect(
        tester.getRect(find.byKey(const Key('menu-reply'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getRect(find.byKey(const Key('menu-copy'))).height,
        greaterThanOrEqualTo(48),
      );
      final pill = tester.getRect(find.byKey(const Key('reaction-pill')));
      expect(pill.left, greaterThanOrEqualTo(0));
      expect(pill.right, lessThanOrEqualTo(320));
      await tester.tap(find.byKey(const Key('menu-reply')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('reply-cancel'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getRect(find.byKey(const Key('chip-$heart'))).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('everything fits at 320 px wide and text 2.0, dark and light', (
      tester,
    ) async {
      for (final dark in [true, false]) {
        await open(
          tester,
          [
            msgU(
              1,
              'where it all started, with a longer line to wrap',
              when(9, 0),
              mine: true,
              reactions: {peerId: laugh},
            ),
            msgU(
              2,
              'and a long answer that wraps onto several lines at this size',
              when(9, 2),
              reply: ChatReply(
                id: uid(1),
                by: meId,
                snippet: 'where it all started, with a longer line to wrap',
                kind: 'text',
              ),
              reactions: {meId: heart, peerId: heart},
            ),
          ],
          size: const Size(320, 640),
          textScale: 2,
          dark: dark,
        );
        expect(tester.takeException(), isNull, reason: 'thread, dark=$dark');
        await longPress(tester, find.textContaining('and a long answer'));
        expect(tester.takeException(), isNull, reason: 'menu, dark=$dark');
        await tester.tap(find.byKey(const Key('menu-reply')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'reply bar, dark=$dark');
        expect(find.byKey(const Key('reply-bar')), findsOneWidget);
      }
    });
  });

  group('contrast (WCAG AA) of the new surfaces', () {
    double ratio(Color a, Color b) {
      final l1 = a.computeLuminance(), l2 = b.computeLuminance();
      final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
      return (hi + .05) / (lo + .05);
    }

    for (final t in [ChatTokens.dark, ChatTokens.light]) {
      final name = t.isDark ? 'dark' : 'light';
      test('chips, menu, reply bar and notice in $name', () {
        final own = Color.alphaBlend(
          t.accent.withValues(alpha: t.isDark ? .2 : .14),
          t.bg,
        );
        expect(
          ratio(t.text, own),
          greaterThanOrEqualTo(4.5),
          reason: 'own chip',
        );
        expect(
          ratio(t.text, t.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'their chip',
        );
        expect(
          ratio(t.text, t.elevated),
          greaterThanOrEqualTo(4.5),
          reason: 'menu text',
        );
        expect(
          ratio(t.accent, t.elevated),
          greaterThanOrEqualTo(4.5),
          reason: 'reply bar and Retry',
        );
        expect(
          ratio(t.textSecondary, t.elevated),
          greaterThanOrEqualTo(4.5),
          reason: 'reply bar line',
        );
        expect(
          ratio(t.error, t.elevated),
          greaterThanOrEqualTo(3),
          reason: 'notice icon',
        );
        // The chip border against the page: the own chip's ring is a UI edge (3:1).
        expect(
          ratio(t.accent, t.bg),
          greaterThanOrEqualTo(3),
          reason: 'own chip ring',
        );
      });

      test('the quote block text in $name bubbles', () {
        final onIncoming = Color.alphaBlend(
          (t.isDark ? Colors.white : Colors.black).withValues(alpha: .07),
          t.incoming,
        );
        expect(
          ratio(t.accent, onIncoming),
          greaterThanOrEqualTo(4.5),
          reason: 'name',
        );
        expect(
          ratio(
            Color.alphaBlend(t.incomingInk.withValues(alpha: .85), onIncoming),
            onIncoming,
          ),
          greaterThanOrEqualTo(4.5),
          reason: 'line',
        );
        for (final tone in [t.outgoingTop, t.outgoingBottom]) {
          final onOutgoing = Color.alphaBlend(
            Colors.black.withValues(alpha: .08),
            tone,
          );
          expect(
            ratio(t.outgoingInk, onOutgoing),
            greaterThanOrEqualTo(4.5),
            reason: 'outgoing',
          );
          expect(
            ratio(
              Color.alphaBlend(
                t.outgoingInk.withValues(alpha: .85),
                onOutgoing,
              ),
              onOutgoing,
            ),
            greaterThanOrEqualTo(4.5),
            reason: 'outgoing line',
          );
        }
      });
    }
  });
}
