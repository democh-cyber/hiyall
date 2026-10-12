import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_jpeg.dart';

import 'chat_photo_helpers.dart';

void main() {
  group('Padme and ciphertext sizes match the Rust core', () {
    test('padme values from the core tests', () {
      for (final (len, want) in [
        (0, 0),
        (1, 1),
        (2, 2),
        (3, 3),
        (4, 4),
        (9, 10),
        (100, 104),
        (1000, 1024),
        (65536, 65536),
        (412000, 417792),
      ]) {
        expect(padme(len), want, reason: 'padme($len)');
      }
    });

    test('size formula: padded length plus a 16 byte tag per chunk', () {
      expect(ciphertextLength(0, 4096), 16);
      expect(ciphertextLength(1, 4096), 17);
      expect(ciphertextLength(412000, 65536), 417792 + 7 * 16);
      expect(ciphertextLength(65536, 65536), 65536 + 16);
    });
  });

  group('descriptor validation', () {
    test('a valid descriptor parses and survives its own JSON', () {
      final att = ChatAttachment.parse(descriptor());
      expect(att.full.blobId, fullId);
      expect(att.thumb.blobId, thumbId);
      expect(att.key, hasLength(32));
      expect(att.caption, 'hello');
      expect(att.uploaded, isTrue);
      final again = ChatAttachment.parse(jsonDecode(jsonEncode(att.toJson())));
      expect(again.toJson(), att.toJson());
      expect(jsonEncode(att.toJson()).length, lessThan(maxDescriptorBytes));
    });

    final bad = <String, void Function(Map<String, dynamic>)>{
      'unknown version': (d) => d['v'] = 2,
      'no key': (d) => d.remove('key'),
      'short key': (d) => d['key'] = base64Encode(List.filled(31, 1)),
      'long key': (d) => d['key'] = base64Encode(List.filled(33, 1)),
      'unpadded key': (d) =>
          d['key'] = (d['key'] as String).replaceAll('=', ''),
      'key not text': (d) => d['key'] = 5,
      'salt not a uuid': (d) => d['salt'] = 'abc',
      'uppercase salt': (d) => d['salt'] = saltId.toUpperCase(),
      'png mime': (d) => d['mime'] = 'image/png',
      'no mime': (d) => d.remove('mime'),
      'zero width': (d) => d['w'] = 0,
      'negative height': (d) => d['h'] = -1,
      'width over 12000': (d) => d['w'] = 12001,
      'height over 12000': (d) => d['h'] = 12001,
      'over 40 megapixels': (d) {
        d['w'] = 12000;
        d['h'] = 4000;
      },
      'fractional width': (d) => d['w'] = 100.5,
      'width as text': (d) => d['w'] = '100',
      'chunk not a power of two': (d) => d['chunk'] = 3000,
      'chunk too small': (d) => d['chunk'] = 2048,
      'chunk too large': (d) => d['chunk'] = 1 << 21,
      'plainLen zero': (d) => d['plainLen'] = 0,
      'ctSize does not match plainLen': (d) => d['ctSize'] = d['ctSize'] + 1,
      'ctSize over the 4 MiB cap': (d) {
        d['plainLen'] = 4194304;
        d['ctSize'] = ciphertextLength(4194304, 65536);
      },
      'ctSize without the tags': (d) => d['ctSize'] = 1024,
      'hash too short': (d) => d['ctSha256'] = base64Encode(List.filled(16, 1)),
      'hash not base64': (d) => d['ctSha256'] = 'not base64!',
      'no blobs': (d) => d.remove('blobs'),
      'blobs not a map': (d) => d['blobs'] = fullId,
      'full blob not a uuid': (d) => d['blobs'] = {'full': 'xyz'},
      'uppercase blob id': (d) => d['blobs'] = {'full': fullId.toUpperCase()},
      'path in blob id': (d) => d['blobs'] = {'full': '../../etc/passwd'},
      'no thumbnail': (d) => d.remove('thumb'),
      'thumbnail not a map': (d) => d['thumb'] = 'x',
      'thumbnail blob missing': (d) =>
          (d['thumb'] as Map<String, dynamic>).remove('blob'),
      'thumbnail over its cap': (d) {
        (d['thumb'] as Map<String, dynamic>)['plainLen'] = 300000;
        (d['thumb'] as Map<String, dynamic>)['ctSize'] = ciphertextLength(
          300000,
          65536,
        );
      },
      'thumbnail size mismatch': (d) =>
          (d['thumb'] as Map<String, dynamic>)['ctSize'] = 5,
      'thumbnail too wide': (d) =>
          (d['thumb'] as Map<String, dynamic>)['w'] = 20000,
      'both blobs the same': (d) =>
          (d['thumb'] as Map<String, dynamic>)['blob'] = fullId,
      'no preview': (d) => d.remove('preview'),
      'wrong preview type': (d) =>
          (d['preview'] as Map<String, dynamic>)['t'] = 'blurhash',
      'preview too short': (d) =>
          (d['preview'] as Map<String, dynamic>)['d'] = base64Encode([1, 2]),
      'preview too long': (d) => (d['preview'] as Map<String, dynamic>)['d'] =
          base64Encode(List.filled(65, 1)),
      'caption not text': (d) => d['caption'] = 7,
      'caption too long': (d) => d['caption'] = 'x' * 1001,
      'descriptor too large': (d) => d['padding'] = 'x' * 4096,
    };
    for (final entry in bad.entries) {
      test('rejects ${entry.key}', () {
        final d = descriptor();
        entry.value(d);
        expect(
          () => ChatAttachment.parse(jsonDecode(jsonEncode(d))),
          throwsFormatException,
        );
      });
    }

    for (final raw in [null, 'text', 5, <Object>[], true]) {
      test('rejects a descriptor that is $raw', () {
        expect(() => ChatAttachment.parse(raw), throwsFormatException);
      });
    }

    test('an absent caption is empty and extra fields are ignored', () {
      final d = descriptor()
        ..remove('caption')
        ..['later'] = 'field';
      expect(ChatAttachment.parse(d).caption, isEmpty);
    });
  });

  group('payload to message', () {
    Map<String, dynamic> body(Object? att, {String kind = 'image'}) => {
      'v': 1,
      'kind': kind,
      'text': photoFallbackText,
      'messageId': 'm1',
      'conversationId': conv,
      'senderId': peerId,
      'sentAt': '2026-10-12T09:00:00Z',
      'att': att,
    };
    ChatMessage read(Map<String, dynamic> b) => messageFromBody(
      b,
      messageId: 'm1',
      conversationId: conv,
      senderId: peerId,
      me: meId,
    );

    test('a valid photo carries its attachment and a preview line', () {
      final m = read(body(descriptor()));
      expect(m.attachment, isNotNull);
      expect(m.unsupportedPhoto, isFalse);
      expect(m.preview, 'hello');
      expect(m.mine, isFalse);
    });

    test('a photo without a caption previews as Photo', () {
      final m = read(body(descriptor()..['caption'] = ''));
      expect(m.preview, 'Photo');
    });

    test('a bad descriptor becomes an unsupported photo, never an error', () {
      for (final att in [null, 'junk', descriptor()..['mime'] = 'image/gif']) {
        final m = read(body(att));
        expect(m.attachment, isNull);
        expect(m.unsupportedPhoto, isTrue);
        expect(m.isPhoto, isTrue);
        expect(m.text, photoFallbackText);
        expect(m.preview, 'Photo');
      }
    });

    test('the metadata binding still applies to photos', () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (b) => b['v'] = 2,
        (b) => b['conversationId'] = 'other',
        (b) => b['senderId'] = meId,
        (b) => b['messageId'] = 'm2',
        (b) => b['text'] = 5,
        (b) => b.remove('text'),
      ]) {
        final b = body(descriptor());
        change(b);
        expect(() => read(b), throwsA(isA<Object>()));
      }
    });

    test('a text message is unaffected by an att field', () {
      final m = read(body(descriptor(), kind: 'text'));
      expect(m.attachment, isNull);
      expect(m.isPhoto, isFalse);
    });
  });

  group('stored history', () {
    test('an attachment, status and failure round trip lean', () {
      final att = ChatAttachment.parse(descriptor());
      final m = ChatMessage(
        messageId: 'm1',
        senderId: meId,
        text: photoFallbackText,
        sentAt: DateTime.utc(2026, 10, 12),
        mine: true,
        attachment: att,
        status: SendStatus.failed,
        failure: 'NETWORK',
      );
      final back = ChatMessage.fromJson(
        jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>,
      );
      expect(back.attachment!.key, att.key);
      expect(back.status, SendStatus.failed);
      expect(back.failure, 'NETWORK');
    });

    test('a sent text message stores no extra fields', () {
      final json = ChatMessage(
        messageId: 'm1',
        senderId: meId,
        text: 'hi',
        sentAt: DateTime.utc(2026, 10, 12),
        mine: true,
      ).toJson();
      expect(json.keys, isNot(containsAll(['att', 'st', 'err', 'bad'])));
      expect(ChatMessage.fromJson(json).status, SendStatus.sent);
    });

    test('a stored descriptor that no longer validates stays readable', () {
      final json = ChatMessage(
        messageId: 'm1',
        senderId: peerId,
        text: photoFallbackText,
        sentAt: DateTime.utc(2026, 10, 12),
        mine: false,
        attachment: ChatAttachment.parse(descriptor()),
      ).toJson();
      (json['att'] as Map)['mime'] = 'image/gif';
      final back = ChatMessage.fromJson(json);
      expect(back.attachment, isNull);
      expect(back.unsupportedPhoto, isTrue);
    });
  });

  group('JPEG header', () {
    test('reads the declared size without decoding', () {
      expect(jpegDimensions(fakeJpeg(1536, 2048)), (w: 1536, h: 2048));
      expect(jpegDimensions(fakeJpeg(1, 1)), (w: 1, h: 1));
    });

    test('refuses anything that is not a JPEG with a frame header', () {
      expect(jpegDimensions(Uint8List.fromList([])), isNull);
      expect(
        jpegDimensions(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
        isNull,
      );
      expect(
        jpegDimensions(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])),
        isNull,
      );
      expect(jpegDimensions(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNull);
      // Truncated in the middle of the frame header.
      expect(jpegDimensions(fakeJpeg(10, 10).sublist(0, 25)), isNull);
      // A zero-sized canvas is not a size.
      expect(jpegDimensions(fakeJpeg(0, 10)), isNull);
    });
  });
}
