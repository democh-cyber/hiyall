import 'dart:typed_data';

/// Removes what an MP4 says about where and with what it was made, without touching the picture or the sound.
///
/// Re-encoding a video does not by itself promise that the location is gone: a phone writes GPS into
/// `udta` (`©xyz`) or into a `meta` box (QuickTime `com.apple.quicktime.location.ISO6709`), and an encoder
/// that copies a clip's container, or one that carries the source's tags across, can keep it. So the app does
/// not rely on the encoder: after encoding it rewrites the file's boxes itself.
///
/// Every `udta`, `meta`, `uuid` (XMP and the like), `XMP_` and `free`/`skip`/`wide` box found at the top level
/// or inside the container boxes of the movie (`moov`, `trak`, `mdia`, `minf`, `stbl`, `edts`, `dinf`, `mvex`,
/// `moof`, `traf`) becomes a `free` box of exactly the same size with a zeroed body, and the creation and
/// modification times in `mvhd`, `tkhd` and `mdhd` are set to zero. The length of every box stays the same, so
/// no offset in the file moves and the video plays exactly as before. What is left is what playback needs: the
/// codec setup, the sample tables and the media itself. The scrubbed file is checked by [remainingMetadata].
///
/// What this does not (and cannot) hide: the picture itself (a visible street sign), the sound, and the
/// length, frame size and encoder settings that any player must read.
const _containers = {
  'moov',
  'trak',
  'mdia',
  'minf',
  'stbl',
  'edts',
  'dinf',
  'mvex',
  'moof',
  'traf',
};
const _removed = {'udta', 'meta', 'uuid', 'XMP_', 'free', 'skip', 'wide'};

class Mp4Box {
  final String type;
  final int start, size, header;
  const Mp4Box(this.type, this.start, this.size, this.header);
  int get bodyStart => start + header;
  int get end => start + size;
}

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

String _type(Uint8List b, int o) => String.fromCharCodes(b.sublist(o, o + 4));

/// The boxes laid out one after another from [from] to [to]. Throws [FormatException] for anything that is
/// not a well-formed run of boxes.
List<Mp4Box> parseBoxes(Uint8List b, int from, int to) {
  final out = <Mp4Box>[];
  var o = from;
  while (o < to) {
    if (to - o < 8) throw const FormatException('truncated box');
    var size = _u32(b, o);
    var header = 8;
    if (size == 1) {
      if (to - o < 16) throw const FormatException('truncated box');
      final high = _u32(b, o + 8), low = _u32(b, o + 12);
      if (high != 0) throw const FormatException('box too large');
      size = low;
      header = 16;
    } else if (size == 0) {
      size = to - o;
    }
    if (size < header || o + size > to) {
      throw const FormatException('bad box size');
    }
    out.add(Mp4Box(_type(b, o + 4), o, size, header));
    o += size;
  }
  return out;
}

/// Metadata boxes still present in [bytes] (their type, in the order found). An empty list means none of the
/// boxes this scrubber removes remain. Throws [FormatException] for a file that is not a well-formed MP4.
List<String> remainingMetadata(Uint8List bytes) {
  final found = <String>[];
  void walk(int from, int to) {
    for (final box in parseBoxes(bytes, from, to)) {
      if (_removed.contains(box.type) && box.type != 'free') {
        // Only a zeroed free box is clean; a free box with a body is "removed" below.
        found.add(box.type);
      } else if (box.type == 'free' ||
          box.type == 'skip' ||
          box.type == 'wide') {
        for (var i = box.bodyStart; i < box.end; i++) {
          if (bytes[i] != 0) {
            found.add('${box.type} with data');
            break;
          }
        }
      } else if (_containers.contains(box.type)) {
        walk(box.bodyStart, box.end);
      }
    }
  }

  walk(0, bytes.length);
  return found;
}

/// A copy of [input] with the metadata boxes blanked and the timestamps zeroed (see the library comment).
/// Throws [FormatException] when [input] is not an MP4 this can read or has no `moov` box.
Uint8List scrubMp4(Uint8List input) {
  final out = Uint8List.fromList(input);
  var sawMoov = false;
  void blank(Mp4Box box) {
    // The size stays; the type becomes 'free' and the body zeros, so the length is the same.
    out.setRange(box.start + 4, box.start + 8, const [0x66, 0x72, 0x65, 0x65]);
    for (var i = box.bodyStart; i < box.end; i++) {
      out[i] = 0;
    }
  }

  void zeroTimes(Mp4Box box) {
    final version = out[box.bodyStart];
    final at = box.bodyStart + 4;
    final len = version == 1 ? 16 : 8;
    if (at + len <= box.end) {
      for (var i = at; i < at + len; i++) {
        out[i] = 0;
      }
    }
  }

  void walk(int from, int to) {
    for (final box in parseBoxes(out, from, to)) {
      if (box.type == 'moov') sawMoov = true;
      if (_removed.contains(box.type)) {
        blank(box);
      } else if (box.type == 'mvhd' ||
          box.type == 'tkhd' ||
          box.type == 'mdhd') {
        zeroTimes(box);
      } else if (_containers.contains(box.type)) {
        walk(box.bodyStart, box.end);
      }
    }
  }

  walk(0, out.length);
  if (!sawMoov) throw const FormatException('no movie box');
  return out;
}
