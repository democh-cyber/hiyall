import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_history.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_thread.dart';

import 'chat_photo_helpers.dart' show conv, meId, peerId;

/// The square boxes in chat screenshots are the test runner's fonts (it has no
/// emoji font), not the app changing text. These tests pin that down: emoji,
/// including joined (ZWJ) sequences, skin tones, flags and keycaps, go through
/// the message model, its JSON, the stored history and the large-emoji
/// detector unchanged, and are counted as the single characters people see.
const family = '👨‍👩‍👧‍👦';
const waving = '👋🏽';
const flagIndia = '🇮🇳';
const flagEngland = '🏴󠁧󠁢󠁥󠁮󠁧󠁿';
const keycap = '1️⃣';
const heart = '❤️';
const couple = '🧑🏻‍🤝‍🧑🏿';

const samples = <String>[
  '😀',
  heart,
  waving,
  family,
  couple,
  flagIndia,
  flagEngland,
  keycap,
  '👍🏽👍🏽',
  '🔥🔥🔥',
  'hey 👋 what’s up 🎉',
  'ok 👩🏽‍💻 shipped it',
  'mixed: a$family b$flagIndia c$keycap',
  'text only',
];

ChatMessage message(String text) => ChatMessage(
  messageId: 'm',
  senderId: peerId,
  text: text,
  sentAt: DateTime(2026, 10, 12, 10),
  mine: false,
);

void main() {
  group('emoji survive the message path unchanged', () {
    test('a received payload becomes a message with the same text', () {
      for (final text in samples) {
        final body = jsonDecode(
          utf8.decode(
            utf8.encode(
              jsonEncode({
                'v': 1,
                'conversationId': conv,
                'senderId': peerId,
                'messageId': 'm1',
                'text': text,
              }),
            ),
          ),
        );
        final m = messageFromBody(
          body as Map<String, dynamic>,
          messageId: 'm1',
          conversationId: conv,
          senderId: peerId,
          me: meId,
        );
        expect(m.text, text, reason: text);
        expect(m.text.runes.toList(), text.runes.toList(), reason: text);
      }
    });

    test('the message JSON (the secure history) round-trips them', () {
      for (final text in samples) {
        final again = ChatMessage.fromJson(
          jsonDecode(jsonEncode(message(text).toJson()))
              as Map<String, dynamic>,
        );
        expect(again.text, text, reason: text);
      }
    });

    test(
      'the stored history gives back the same text after a restart',
      () async {
        final store = MemoryChatStore();
        String key(String id) => 'h:$id';
        final first = ChatHistory(store, key);
        for (var i = 0; i < samples.length; i++) {
          await first.append(
            conv,
            ChatMessage(
              messageId: 'm$i',
              senderId: peerId,
              text: samples[i],
              sentAt: DateTime(2026, 10, 12, 10, i),
              mine: false,
            ),
          );
        }
        // A new history over the same store has no memory of the first.
        final read = await ChatHistory(store, key).read(conv);
        expect([for (final m in read) m.text], samples);
      },
    );

    test('the list preview and the report evidence use the text as it is', () {
      for (final text in samples) {
        expect(message(text).preview, text);
        expect(previewFor(message(text), username: 'x').text, text.trim());
      }
    });
  });

  group('the large-emoji detector and the grapheme count', () {
    test(
      'joined sequences, skin tones, flags and keycaps are one character',
      () {
        for (final text in [
          family,
          waving,
          flagIndia,
          flagEngland,
          keycap,
          heart,
        ]) {
          expect(text.characters.length, 1, reason: text);
          expect(isEmojiOnly(text), isTrue, reason: text);
        }
        expect(couple.characters.length, 1);
        expect(isEmojiOnly(couple), isTrue);
      },
    );

    test('up to three, with or without spaces, and nothing else', () {
      expect(isEmojiOnly('🔥🔥'), isTrue);
      expect(isEmojiOnly('🔥 🔥 🔥'), isTrue);
      expect(isEmojiOnly('$family$flagIndia$waving'), isTrue);
      expect(isEmojiOnly('$family$family$family$family'), isFalse);
      expect(isEmojiOnly('hi 👋'), isFalse);
      expect(isEmojiOnly('👋 hi'), isFalse);
      expect(isEmojiOnly('1'), isFalse);
      expect(isEmojiOnly('#'), isFalse);
      expect(isEmojiOnly(''), isFalse);
      expect(isEmojiOnly('   '), isFalse);
    });
  });

  group('the large rendering', () {
    Future<void> pumpBubble(WidgetTester tester, String text) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: hiyallTheme(Brightness.dark),
          home: Scaffold(
            body: ChatBubble(
              row: MessageRow(message(text), first: true, last: true),
              engine: null,
              conversationId: conv,
              peerName: 'Niko',
              peerId: peerId,
              peerAvatarUrl: null,
              seen: false,
            ),
          ),
        ),
      );
    }

    testWidgets('draws the exact string, sized by how many characters it is', (
      tester,
    ) async {
      for (final (text, size) in [
        (family, 52.0),
        (waving, 52.0),
        ('$family$flagIndia', 44.0),
        ('$heart$keycap$waving', 38.0),
      ]) {
        await pumpBubble(tester, text);
        final widget = tester.widget<Text>(find.byKey(const Key('emoji-m')));
        expect(widget.data, text);
        expect(widget.style!.fontSize, size, reason: text);
      }
    });

    testWidgets('a sentence with emoji stays a normal bubble, text intact', (
      tester,
    ) async {
      const text = 'see you 👋🏽 at 8 $family';
      await pumpBubble(tester, text);
      expect(find.byKey(const Key('emoji-m')), findsNothing);
      expect(find.text(text), findsOneWidget);
    });
  });
}
