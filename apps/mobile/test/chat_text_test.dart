import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_padding.dart';
import 'package:hiyall/core/chat/chat_text.dart';

// The chat text rules against the vectors the API's Go tests read too
// (services/api/internal/domain/testdata/text_vectors.json).

String str(Object? codes) => String.fromCharCodes([
  for (final c in (codes as List?) ?? const []) c as int,
]);

void main() {
  final vectors = (jsonDecode(
    File('../../services/api/internal/domain/testdata/text_vectors.json')
        .readAsStringSync(),
  ) as List).cast<Map<String, dynamic>>();

  test('the shared vectors are there', () {
    expect(vectors.length, greaterThan(100));
  });

  group('shared vectors', () {
    test('isCleanText agrees with the API for every vector', () {
      for (final v in vectors) {
        final input = str(v['input']);
        expect(
          isCleanText(input, multiline: v['multiline'] as bool),
          v['clean'],
          reason: '${v['name']} ${v['input']}',
        );
      }
    });

    test('normalizeNfc agrees with the API for every vector', () {
      for (final v in vectors) {
        expect(
          normalizeNfc(str(v['input'])).runes.toList(),
          v['nfc'],
          reason: '${v['name']} ${v['input']}',
        );
      }
    });

    test('sanitizeText always yields clean NFC text and keeps clean text', () {
      for (final v in vectors) {
        final multiline = v['multiline'] as bool;
        final input = str(v['input']);
        final out = sanitizeText(input, multiline: multiline);
        final reason = '${v['name']} ${v['input']}';
        if (v['appKeeps'] == true) {
          expect(out, input, reason: reason);
          expect(isCleanText(input), isFalse, reason: reason);
          continue;
        }
        expect(isCleanText(out, multiline: multiline), isTrue, reason: reason);
        expect(normalizeNfc(out), out, reason: reason);
        if (v['clean'] == true && normalizeNfc(input) == input) {
          expect(identical(out, input), isTrue, reason: reason);
        }
        if (v['stripped'] != null) {
          expect(out, normalizeNfc(str(v['stripped'])), reason: reason);
        }
      }
    });
  });

  group('sanitizing', () {
    test('plain text is returned as the same object', () {
      const text = 'hello, wörld! 😀 (a\nb)';
      expect(identical(sanitizeText(text), text), isTrue);
    });

    test('a lone surrogate is dropped and never accepted', () {
      final bad = 'a${String.fromCharCode(0xD800)}b';
      expect(isCleanText(bad), isFalse);
      expect(sanitizeText(bad), 'ab');
    });

    test('a one-line field loses line breaks and tabs', () {
      expect(sanitizeText('a\nb\tc', multiline: false), 'abc');
      expect(isCleanText('a\nb', multiline: false), isFalse);
    });

    test('emoji sequences keep their joiners', () {
      const family = '👨‍👩‍👧';
      expect(sanitizeText(family), family);
      expect(sanitizeText('‍$family‍'), family);
    });

    test('subdivision flags keep their tags, other tags go', () {
      const england =
          '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}';
      expect(sanitizeText('a${england}b'), 'a${england}b');
      expect(sanitizeText('a\u{E0041}\u{E007F}b'), 'ab');
      // No cancel tag, or not after the flag: removed.
      expect(sanitizeText('\u{1F3F4}\u{E0067}\u{E0062}'), '\u{1F3F4}');
      expect(sanitizeText('x\u{E0067}\u{E0062}\u{E007F}'), 'x');
    });

    test('the combining mark run is cut at five, after composing', () {
      expect(
        sanitizeText('a${'̀' * 9}').runes.length,
        // "à" composes the first mark; five more follow.
        6,
      );
    });

    test('displayText is the same cleaning', () {
      expect(displayText('gnp\u202Eexe'), 'gnpexe');
      expect(displayText('x\u200By'), 'xy');
      expect(displayText('u v'), 'uv');
    });

    test('NFC composes Hangul, reorders marks and uses singletons', () {
      expect(normalizeNfc('한'), '한');
      expect(normalizeNfc('ạ̇'), normalizeNfc('ạ̇'));
      expect(normalizeNfc('Å'), 'Å');
      expect(normalizeNfc('é'), 'é');
    });
  });

  group('padding (F16)', () {
    test('buckets', () {
      expect(paddedPayloadLength(1), 64);
      expect(paddedPayloadLength(64), 64);
      expect(paddedPayloadLength(65), 128);
      expect(paddedPayloadLength(4096), 4096);
      expect(paddedPayloadLength(4097), 5120);
      expect(paddedPayloadLength(13000), 13000);
    });

    test('a padded payload lands exactly on its bucket and parses back', () {
      for (final n in [1, 5, 40, 120, 300, 900, 2000, 4000, 7000]) {
        final body = {
          'v': 1,
          'kind': 'text',
          'text': List.filled(n, 'x').join(),
        };
        final json = encodePadded(body, Random(1));
        final bytes = utf8.encode(json).length;
        final plain = utf8.encode(jsonEncode(body)).length + padOverhead;
        expect(bytes, paddedPayloadLength(plain), reason: 'n=$n');
        final back = jsonDecode(json) as Map;
        expect(back['text'], body['text']);
        expect(isValidPad(back['pad']), isTrue);
      }
    });

    test('short messages of different lengths look alike', () {
      int size(String t) => utf8
          .encode(encodePadded({'v': 1, 'kind': 'text', 'text': t}, Random(1)))
          .length;
      expect(size('hi'), size('ok see you'));
    });

    test('non-ASCII text is measured in bytes', () {
      final body = {'v': 1, 'text': '😀' * 20};
      final json = encodePadded(body, Random(1));
      expect(utf8.encode(json).length, 128);
    });

    test('pads are validated', () {
      expect(isValidPad(null), isTrue);
      expect(isValidPad(''), isTrue);
      expect(isValidPad(5), isFalse);
      expect(isValidPad('a' * (maxPadLength + 1)), isFalse);
    });
  });
}
