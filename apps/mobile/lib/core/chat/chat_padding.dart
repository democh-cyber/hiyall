import 'dart:convert';
import 'dart:math';

// Padding of text payloads (audit F16). The relay sees the size of every
// envelope, and a message's length is a lot to give away. A text payload is
// padded, inside the encryption, to one of a few sizes, so a 5-letter and a
// 50-letter message look alike. The filler is a `pad` string of random
// base64url characters (it does not compress and says nothing). Receivers
// ignore it, so messages without one (older builds) still parse.

/// The sizes, in bytes of the UTF-8 JSON payload, that a short payload is
/// padded up to.
const paddingBuckets = [64, 128, 256, 512, 1024, 2048, 4096];

/// Bytes `,"pad":""` adds to a payload before any filler.
const padOverhead = 9;

/// Above the last bucket the size is rounded up to a multiple of this, and
/// only up to [padCeiling]: a relay envelope is capped at 16 KiB.
const padStep = 1024;
const padCeiling = 12 * 1024;

/// The longest `pad` a receiver accepts, in characters.
const maxPadLength = 16 * 1024;

/// The padded payload size for a payload of [length] bytes that already
/// includes the room for the `pad` field, or [length] itself when it is too
/// big to pad.
int paddedPayloadLength(int length) {
  for (final bucket in paddingBuckets) {
    if (length <= bucket) return bucket;
  }
  final rounded = (length + padStep - 1) ~/ padStep * padStep;
  return rounded <= padCeiling ? rounded : length;
}

const _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

/// [body] as JSON with a `pad` that brings the UTF-8 length up to its bucket.
String encodePadded(Map<String, dynamic> body, Random random) {
  final plain = jsonEncode(body);
  final length = utf8.encode(plain).length + padOverhead;
  if (length > padCeiling) return plain; // too big to pad
  final fill = paddedPayloadLength(length) - length;
  final pad = StringBuffer();
  for (var i = 0; i < fill; i++) {
    pad.write(_alphabet[random.nextInt(64)]);
  }
  return jsonEncode({...body, 'pad': pad.toString()});
}

/// Whether a received payload's `pad` (when it has one) is acceptable: a
/// string of at most [maxPadLength] characters. It is never read otherwise.
bool isValidPad(Object? pad) =>
    pad == null || (pad is String && pad.length <= maxPadLength);
