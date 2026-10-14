import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'chat_text.dart';

/// What the older apps show for a photo they cannot open; also the `text` of
/// every photo message that carries no caption.
const photoFallbackText = 'Sent a photo. Update Hiyall to view it.';

/// Largest caption this app sends; a longer one is refused on receipt.
const maxCaption = 500;

/// The descriptor sizes the server and the report endpoint both bound.
const maxDescriptorBytes = 4096;

/// Ciphertext caps per blob, as the server enforces them.
const maxFullCiphertext = 4 << 20;
const maxThumbCiphertext = 256 << 10;

/// A picked photo above this is refused by the Rust core anyway.
const maxPhotoInput = 64 << 20;

/// The chunk size this app sends; the descriptor carries it so it can change.
const attachmentChunk = 65536;
const attachmentMime = 'image/jpeg';

/// What a received descriptor may claim. The sender's own caps are the same:
/// the full image is at most 2048 px on its long edge and 4 MP (2048 x 2048 is
/// exactly 4 Mi pixels), the thumbnail at most 320 px. A descriptor that
/// promises more is refused, so a hostile peer cannot make this phone decode
/// something huge.
const maxFullSide = 2048;
const maxThumbSide = 320;
const maxPixels = 4 << 20;
const maxThumbPixels = maxThumbSide * maxThumbSide;

enum SendStatus { sending, failed, sent }

enum BlobRole { full, thumb }

/// Padme rounding, identical to the Rust core's `padme`.
int padme(int len) {
  if (len < 2) return len;
  final e = len.bitLength - 1;
  final s = e.bitLength;
  final mask = (1 << (e - s)) - 1;
  return (len + mask) & ~mask;
}

/// The exact ciphertext length for a plaintext length, as the core produces it.
int ciphertextLength(int plainLen, int chunk) {
  final padded = padme(plainLen);
  final chunks = padded == 0 ? 1 : (padded + chunk - 1) ~/ chunk;
  return padded + chunks * 16;
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
bool isCanonicalUuid(String value) => _uuid.hasMatch(value);

String b64(List<int> bytes) => base64Encode(bytes);

/// Strict standard padded base64: what we write is the only thing we read.
Uint8List _bytes64(
  Object? raw,
  String what, {
  int? length,
  int? min,
  int? max,
}) {
  if (raw is! String) throw FormatException('$what is not text');
  final Uint8List bytes;
  try {
    bytes = base64Decode(raw);
  } on FormatException {
    throw FormatException('$what is not base64');
  }
  if (base64Encode(bytes) != raw) {
    throw FormatException('$what is not canonical');
  }
  if (length != null && bytes.length != length) {
    throw FormatException('$what has the wrong length');
  }
  if (min != null && bytes.length < min || max != null && bytes.length > max) {
    throw FormatException('$what has the wrong length');
  }
  return bytes;
}

int _int(Object? raw, String what, int min, int max) {
  if (raw is! int || raw < min || raw > max) {
    throw FormatException('$what is out of range');
  }
  return raw;
}

String _id(Object? raw, String what) {
  if (raw is! String || !isCanonicalUuid(raw)) {
    throw FormatException('$what is not an id');
  }
  return raw;
}

/// One ciphertext blob of an attachment: the full image or its thumbnail.
class BlobPart {
  /// Null only while the sender is still uploading; received parts always have it.
  final String? blobId;
  final int w, h, plainLen, ctSize;

  /// Raw SHA-256 of the ciphertext.
  final Uint8List ctSha256;
  const BlobPart({
    required this.blobId,
    required this.w,
    required this.h,
    required this.plainLen,
    required this.ctSize,
    required this.ctSha256,
  });

  BlobPart withId(String? id) => BlobPart(
    blobId: id,
    w: w,
    h: h,
    plainLen: plainLen,
    ctSize: ctSize,
    ctSha256: ctSha256,
  );
}

/// The decrypted `att` descriptor of an image message. It holds the key, so it
/// lives only in the encrypted payload, the local history and, with the
/// reporter's consent, a report.
///
/// `salt` is a per-attachment random id that stands where the Rust core takes a
/// blob id: the server hands out blob ids only after it has the ciphertext's
/// hash, so the id cannot be an input to that ciphertext.
class ChatAttachment {
  final Uint8List key;
  final String salt, mime, caption;
  final int chunk;
  final BlobPart full, thumb;
  final Uint8List preview;
  const ChatAttachment({
    required this.key,
    required this.salt,
    required this.mime,
    required this.chunk,
    required this.full,
    required this.thumb,
    required this.preview,
    this.caption = '',
  });

  int get w => full.w;
  int get h => full.h;
  double get aspect => h == 0 ? 1 : w / h;
  bool get uploaded => full.blobId != null && thumb.blobId != null;
  BlobPart part(BlobRole role) => role == BlobRole.full ? full : thumb;

  ChatAttachment withBlobs({String? fullId, String? thumbId}) => ChatAttachment(
    key: key,
    salt: salt,
    mime: mime,
    chunk: chunk,
    full: full.withId(fullId),
    thumb: thumb.withId(thumbId),
    preview: preview,
    caption: caption,
  );

  /// The descriptor exactly as it travels inside the message. Both blob ids
  /// must be known.
  Map<String, dynamic> toJson() {
    assert(uploaded, 'a descriptor needs both blob ids');
    return {
      'v': 1,
      'key': b64(key),
      'salt': salt,
      'mime': mime,
      'w': full.w,
      'h': full.h,
      'chunk': chunk,
      'plainLen': full.plainLen,
      'ctSize': full.ctSize,
      'ctSha256': b64(full.ctSha256),
      'blobs': {'full': full.blobId},
      'thumb': {
        'blob': thumb.blobId,
        'w': thumb.w,
        'h': thumb.h,
        'plainLen': thumb.plainLen,
        'ctSize': thumb.ctSize,
        'ctSha256': b64(thumb.ctSha256),
      },
      'preview': {'t': 'thumbhash', 'd': b64(preview)},
      'caption': caption,
    };
  }

  /// The same shape for local storage while blob ids are still unknown.
  Map<String, dynamic> toLocalJson() => {
    'v': 1,
    'key': b64(key),
    'salt': salt,
    'mime': mime,
    'w': full.w,
    'h': full.h,
    'chunk': chunk,
    'plainLen': full.plainLen,
    'ctSize': full.ctSize,
    'ctSha256': b64(full.ctSha256),
    if (full.blobId != null) 'blobs': {'full': full.blobId},
    'thumb': {
      if (thumb.blobId != null) 'blob': thumb.blobId,
      'w': thumb.w,
      'h': thumb.h,
      'plainLen': thumb.plainLen,
      'ctSize': thumb.ctSize,
      'ctSha256': b64(thumb.ctSha256),
    },
    'preview': {'t': 'thumbhash', 'd': b64(preview)},
    'caption': caption,
  };

  /// Reads our own stored form back (blob ids may be missing).
  factory ChatAttachment.fromLocal(Object? raw) =>
      ChatAttachment.parse(raw, allowUnsent: true);

  /// Strictly validates a descriptor from the network. Anything doubtful throws
  /// a [FormatException]; nothing is trusted because the key unlocked it: the
  /// peer, or a hostile sender, wrote every field.
  factory ChatAttachment.parse(Object? raw, {bool allowUnsent = false}) {
    if (raw is! Map) throw const FormatException('descriptor is not an object');
    if (jsonEncode(raw).length > maxDescriptorBytes) {
      throw const FormatException('descriptor is too large');
    }
    if (raw['v'] != 1) {
      throw const FormatException('unknown descriptor version');
    }
    final key = _bytes64(raw['key'], 'key', length: 32);
    final salt = _id(raw['salt'], 'salt');
    if (raw['mime'] != attachmentMime) {
      throw const FormatException('unsupported type');
    }
    final chunk = _int(raw['chunk'], 'chunk', 4096, 1 << 20);
    if (chunk & (chunk - 1) != 0) throw const FormatException('bad chunk size');
    final thumbRaw = raw['thumb'];
    final blobs = raw['blobs'];
    if (thumbRaw is! Map) throw const FormatException('no thumbnail');
    String? blobOf(Object? value, String what) {
      if (allowUnsent && value == null) return null;
      return _id(value, what);
    }

    BlobPart part(
      Map m,
      Object? id,
      String what,
      int cap,
      int side,
      int pixels,
    ) {
      final w = _int(m['w'], '$what width', 1, side);
      final h = _int(m['h'], '$what height', 1, side);
      if (w * h > pixels) throw FormatException('$what is too large');
      final plainLen = _int(m['plainLen'], '$what length', 1, cap);
      final ctSize = _int(m['ctSize'], '$what size', 1, cap);
      if (ctSize != ciphertextLength(plainLen, chunk)) {
        throw FormatException('$what size does not match');
      }
      return BlobPart(
        blobId: blobOf(id, '$what blob'),
        w: w,
        h: h,
        plainLen: plainLen,
        ctSize: ctSize,
        ctSha256: _bytes64(m['ctSha256'], '$what hash', length: 32),
      );
    }

    final full = part(
      raw,
      blobs is Map ? blobs['full'] : null,
      'image',
      maxFullCiphertext,
      maxFullSide,
      maxPixels,
    );
    final thumb = part(
      thumbRaw,
      thumbRaw['blob'],
      'thumbnail',
      maxThumbCiphertext,
      maxThumbSide,
      maxThumbPixels,
    );
    if (full.blobId != null && full.blobId == thumb.blobId) {
      throw const FormatException('blobs repeat');
    }
    final preview = raw['preview'];
    if (preview is! Map || preview['t'] != 'thumbhash') {
      throw const FormatException('no preview');
    }
    final caption = raw['caption'] ?? '';
    if (caption is! String || caption.runes.length > maxCaption) {
      throw const FormatException('bad caption');
    }
    return ChatAttachment(
      key: key,
      salt: salt,
      mime: attachmentMime,
      chunk: chunk,
      full: full,
      thumb: thumb,
      preview: _bytes64(preview['d'], 'preview', min: 5, max: 64),
      caption: displayText(caption),
    );
  }
}

/// A random (version 4) UUID in canonical lowercase form.
String newUuid4(Random random) {
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
