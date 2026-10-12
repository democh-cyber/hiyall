import 'dart:typed_data';

/// The pixel size a JPEG declares, read from its first frame header without
/// decoding anything; null if the bytes are not a JPEG or have no frame header
/// before the image data starts. Checking this first stops a hostile file
/// from asking the decoder for a huge canvas.
({int w, int h})? jpegDimensions(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8 || b[2] != 0xFF) return null;
  var i = 2;
  while (i + 3 < b.length) {
    if (b[i] != 0xFF) return null;
    while (i < b.length && b[i] == 0xFF) {
      i++;
    }
    if (i >= b.length) return null;
    final marker = b[i++];
    // Markers without a length: restart markers, TEM and SOI.
    if (marker == 0x01 ||
        marker == 0xD8 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null;
    if (i + 1 >= b.length) return null;
    final length = (b[i] << 8) | b[i + 1];
    if (length < 2) return null;
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (length < 8 || i + 6 >= b.length) return null;
      final h = (b[i + 3] << 8) | b[i + 4], w = (b[i + 5] << 8) | b[i + 6];
      return w == 0 || h == 0 ? null : (w: w, h: h);
    }
    i += length;
  }
  return null;
}
