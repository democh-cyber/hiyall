import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/features/chat_starters.dart';

const onboardingInterests = [
  'Music',
  'Technology',
  'Travel',
  'Photography',
  'Movies',
  'Art',
  'Gaming',
  'Reading',
  'Fitness',
  'Food',
  'Nature',
  'Learning',
];

/// Things a starter must never ask about or hint at.
final _forbidden = RegExp(
  r'\b(age|old are you|how old|school|college|where do you live|where are you from|address|phone number|your number|snap|insta|whatsapp|email|selfie|pic of you|single|date|sexy|cute|hot|body)\b',
  caseSensitive: false,
);

void main() {
  group('sharedInterestLine', () {
    test('nothing shared gives no line', () {
      expect(sharedInterestLine(const []), isNull);
      expect(sharedInterestLine(const ['', '  ']), isNull);
    });

    test('one interest reads naturally, with the right verb and emoji', () {
      expect(sharedInterestLine(const ['Music']), 'You both love Music 🎧');
      expect(sharedInterestLine(const ['Gaming']), 'You both like Gaming 🎮');
      expect(
        sharedInterestLine(const ['Technology']),
        'You both like Technology 💻',
      );
      expect(sharedInterestLine(const ['Travel']), 'You both love Travel ✈️');
      expect(sharedInterestLine(const ['Food']), 'You both love Food 🍜');
    });

    test('the match is case-insensitive and keeps the spelling nice', () {
      expect(sharedInterestLine(const ['music']), 'You both love Music 🎧');
      expect(sharedInterestLine(const [' GAMING ']), 'You both like Gaming 🎮');
    });

    test('two interests share one verb; a third is not mentioned', () {
      expect(
        sharedInterestLine(const ['Music', 'Travel', 'Art']),
        'You both love Music 🎧 and Travel ✈️',
      );
      expect(
        sharedInterestLine(const ['Music', 'Gaming']),
        'You both like Music 🎧 and Gaming 🎮',
      );
    });

    test('a custom interest is shown as typed, cut when very long', () {
      expect(
        sharedInterestLine(const ['Skateboarding']),
        'You both like Skateboarding',
      );
      final long = sharedInterestLine([List.filled(60, 'x').join()])!;
      expect(long.endsWith('…'), isTrue);
      expect(long.length, lessThan(50));
    });
  });

  group('startersFor', () {
    const ids = [
      '00000000-0000-4000-8000-0000000000c1',
      '00000000-0000-4000-8000-0000000000c2',
      '00000000-0000-4000-8000-0000000000c3',
      '019a4000-0000-7000-8000-000000000123',
    ];

    test('three or four, no repeats', () {
      for (final id in ids) {
        for (final shared in [
          const <String>[],
          const ['Music'],
          const ['Music', 'Gaming'],
          const ['Skateboarding'],
        ]) {
          final out = startersFor(id, shared);
          expect(out.length, inInclusiveRange(3, 4), reason: '$id $shared');
          expect(out.toSet().length, out.length, reason: '$id $shared');
        }
      }
    });

    test('the same chat always gets the same set', () {
      for (final id in ids) {
        expect(
          startersFor(id, const ['Music']),
          startersFor(id, const ['Music']),
        );
        expect(startersFor(id, const []), startersFor(id, const []));
      }
    });

    test('different chats rotate through the pool', () {
      final sets = {
        for (var i = 0; i < 40; i++)
          startersFor(
            '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            const ['Music'],
          ).join('|'),
      };
      expect(sets.length, greaterThan(4));
      final generic = {
        for (var i = 0; i < 40; i++) startersFor('id-$i', const []).join('|'),
      };
      expect(generic.length, greaterThan(4));
    });

    test('a shared interest leads with ideas about it', () {
      for (final interest in onboardingInterests) {
        final topic = topicFor(interest)!;
        for (final id in ids) {
          final out = startersFor(id, [interest]);
          expect(
            out.take(2).every(topic.starters.contains),
            isTrue,
            reason: '$interest $id $out',
          );
        }
      }
      // Two interests: one idea from each.
      final out = startersFor(ids.first, const ['Music', 'Travel']);
      expect(topicFor('Music')!.starters.contains(out[0]), isTrue);
      expect(topicFor('Travel')!.starters.contains(out[1]), isTrue);
    });

    test('every common interest has a topic with four openers', () {
      expect(interestTopics.map((t) => t.name), onboardingInterests);
      for (final t in interestTopics) {
        expect(t.starters.length, 4, reason: t.name);
        expect(t.emoji, isNotEmpty);
        expect(['love', 'like'], contains(t.verb));
      }
    });

    test('unknown or empty interests fall back to general openers', () {
      for (final shared in [
        const <String>[],
        const ['Skateboarding'],
      ]) {
        final out = startersFor(ids.first, shared);
        expect(out.every(genericStarters.contains), isTrue);
        expect(out.length, 4);
      }
    });

    test('every starter is short, casual and safe', () {
      final all = [
        ...genericStarters,
        for (final t in interestTopics) ...t.starters,
      ];
      for (final s in all) {
        expect(s.length, lessThanOrEqualTo(40), reason: s);
        expect(s.trim(), s, reason: s);
        expect(_forbidden.hasMatch(s), isFalse, reason: s);
        expect(s.contains('!!'), isFalse, reason: s);
      }
    });
  });

  group('parseSharedInterests', () {
    test('missing, null and malformed values are empty', () {
      expect(parseSharedInterests(null), isEmpty);
      expect(parseSharedInterests('Music'), isEmpty);
      expect(parseSharedInterests(42), isEmpty);
      expect(parseSharedInterests({'a': 1}), isEmpty);
      expect(parseSharedInterests(const []), isEmpty);
    });

    test('keeps strings, drops the rest, at most three', () {
      expect(parseSharedInterests(['Music', 3, null, '', '  ', 'Art']), [
        'Music',
        'Art',
      ]);
      expect(parseSharedInterests(['a', 'b', 'c', 'd']), ['a', 'b', 'c']);
    });

    test('the conversation model defaults to none', () {
      const c = ChatConversation('c', 'p', 'Niko', 'niko', null);
      expect(c.sharedInterests, isEmpty);
      const d = ChatConversation(
        'c',
        'p',
        'Niko',
        'niko',
        null,
        sharedInterests: ['Music'],
      );
      expect(d.sharedInterests, ['Music']);
    });
  });
}
