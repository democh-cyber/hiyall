import 'dart:convert';
import 'dart:typed_data';

import 'chat_attachment.dart';

// Voice messages and videos (docs/security/14-encrypted-chat-attachments.md, "Voice and video").
// Both travel as the same kind of encrypted blob as a photo: the audio or video file is encrypted on the
// phone, the ciphertext goes straight to storage, and the key, hash, duration and waveform travel inside the
// end-to-end encrypted message. The server sees a size, never a kind, a length or a mime type.

/// What the older apps show for a voice message or a video they cannot play; also the `text` of every such
/// message.
const voiceFallbackText = 'Sent a voice message. Update Hiyall to play it.';
const videoFallbackText = 'Sent a video. Update Hiyall to watch it.';

/// The audio of a voice message is AAC in an MP4 (M4A) container, a video is MP4 (H.264 and AAC).
const voiceMime = 'audio/mp4';
const videoMime = 'video/mp4';

/// Longest voice message, in milliseconds (Entitlements.VoiceMaxSeconds on the server is the same 300 s) and
/// the shortest one this app sends. A received descriptor may claim at most the longest.
const maxVoiceMs = 300 * 1000;
const minVoiceSendMs = 1000;
const minMediaMs = 200;

/// Longest video this app sends and accepts (Entitlements.VideoMaxSeconds), and the biggest file the sender
/// produces before encryption. The server's own cap is on the ciphertext: 8 MiB for a voice message, 40 MiB
/// for a video. Padme rounding adds at most about 3 % at these sizes, so a 32 MiB file stays under 40 MiB.
const maxVideoMs = 60 * 1000;
const maxVideoPlain = 32 << 20;
const maxVoiceCiphertext = 8 << 20;
const maxVideoCiphertext = 40 << 20;

/// What a received video descriptor may claim: at most 1280 x 720 either way round. The sender produces 720p
/// at most; a descriptor that promises more is refused, so a hostile peer cannot make this phone decode a
/// huge picture.
const maxVideoLongSide = 1280;
const maxVideoShortSide = 720;

/// The waveform of a voice message: one byte (0 to 255) per bar, at most [maxWaveBytes] bars.
const maxWaveBytes = 64;
const minWaveBytes = 1;

/// How many bars a recording is reduced to.
const waveBars = 48;

String _b64(List<int> bytes) => base64Encode(bytes);

Uint8List _bytes(Object? raw, String what, {int? length, int? min, int? max}) {
  if (raw is! String) throw FormatException('$what is not text');
  final Uint8List bytes;
  try {
    bytes = base64Decode(raw);
  } on FormatException {
    throw FormatException('$what is not base64');
  }
  if (_b64(bytes) != raw) throw FormatException('$what is not canonical');
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

String _uuid(Object? raw, String what) {
  if (raw is! String || !isCanonicalUuid(raw)) {
    throw FormatException('$what is not an id');
  }
  return raw;
}

/// One ciphertext blob of a voice message or a video: its id (null only while the sender is still
/// uploading), the plaintext and ciphertext lengths and the raw SHA-256 of the ciphertext.
class MediaPart {
  final String? blobId;
  final int plainLen, ctSize;
  final Uint8List ctSha256;
  const MediaPart({
    required this.blobId,
    required this.plainLen,
    required this.ctSize,
    required this.ctSha256,
  });

  MediaPart withId(String? id) => MediaPart(
    blobId: id,
    plainLen: plainLen,
    ctSize: ctSize,
    ctSha256: ctSha256,
  );

  Map<String, dynamic> _fields() => {
    'plainLen': plainLen,
    'ctSize': ctSize,
    'ctSha256': _b64(ctSha256),
  };

  static MediaPart _parse(
    Map m,
    Object? id,
    String what,
    int chunk,
    int cap, {
    required bool allowUnsent,
  }) {
    String? blobId;
    if (id == null && allowUnsent) {
      blobId = null;
    } else {
      blobId = _uuid(id, '$what blob');
    }
    final plainLen = _int(m['plainLen'], '$what length', 1, cap);
    final ctSize = _int(m['ctSize'], '$what size', 1, cap);
    if (ctSize != ciphertextLength(plainLen, chunk)) {
      throw FormatException('$what size does not match');
    }
    return MediaPart(
      blobId: blobId,
      plainLen: plainLen,
      ctSize: ctSize,
      ctSha256: _bytes(m['ctSha256'], '$what hash', length: 32),
    );
  }
}

/// Everything needed to fetch, verify and decrypt one blob: what the descriptor of any kind says about it.
class BlobSpec {
  final String blobId, role, salt, mime;
  final Uint8List key;
  final int chunk, plainLen, ctSize;
  final Uint8List ctSha256;
  const BlobSpec({
    required this.blobId,
    required this.role,
    required this.salt,
    required this.mime,
    required this.key,
    required this.chunk,
    required this.plainLen,
    required this.ctSize,
    required this.ctSha256,
  });
}

/// The decrypted `att` descriptor of a voice message. Like a photo's it holds the key, so it lives only in the
/// encrypted payload, the local history and, with the reporter's consent, a report.
class VoiceAttachment {
  final Uint8List key;
  final String salt;
  final int chunk;
  final MediaPart part;

  /// Length in milliseconds, as the sender measured it.
  final int durationMs;

  /// One byte per bar (0 to 255), at most [maxWaveBytes].
  final Uint8List wave;
  const VoiceAttachment({
    required this.key,
    required this.salt,
    required this.chunk,
    required this.part,
    required this.durationMs,
    required this.wave,
  });

  bool get uploaded => part.blobId != null;

  VoiceAttachment withBlob(String? id) => VoiceAttachment(
    key: key,
    salt: salt,
    chunk: chunk,
    part: part.withId(id),
    durationMs: durationMs,
    wave: wave,
  );

  BlobSpec get spec => BlobSpec(
    blobId: part.blobId!,
    role: 'voice',
    salt: salt,
    mime: voiceMime,
    key: key,
    chunk: chunk,
    plainLen: part.plainLen,
    ctSize: part.ctSize,
    ctSha256: part.ctSha256,
  );

  Map<String, dynamic> toLocalJson() => {
    'v': 1,
    'key': _b64(key),
    'salt': salt,
    'mime': voiceMime,
    'chunk': chunk,
    ...part._fields(),
    if (part.blobId != null) 'blobs': {'voice': part.blobId},
    'dur': durationMs,
    'wave': _b64(wave),
  };

  /// The descriptor exactly as it travels inside the message: the blob id must be known.
  Map<String, dynamic> toJson() {
    assert(uploaded, 'a descriptor needs its blob id');
    return toLocalJson();
  }

  factory VoiceAttachment.fromLocal(Object? raw) =>
      VoiceAttachment.parse(raw, allowUnsent: true);

  /// Strictly validates a descriptor from the network. Anything doubtful throws a [FormatException]: the
  /// peer, or a hostile sender, wrote every field.
  factory VoiceAttachment.parse(Object? raw, {bool allowUnsent = false}) {
    if (raw is! Map) throw const FormatException('descriptor is not an object');
    if (jsonEncode(raw).length > maxDescriptorBytes) {
      throw const FormatException('descriptor is too large');
    }
    if (raw['v'] != 1) {
      throw const FormatException('unknown descriptor version');
    }
    if (raw['mime'] != voiceMime) {
      throw const FormatException('unsupported type');
    }
    final chunk = _int(raw['chunk'], 'chunk', 4096, 1 << 20);
    if (chunk & (chunk - 1) != 0) throw const FormatException('bad chunk size');
    final blobs = raw['blobs'];
    final part = MediaPart._parse(
      raw,
      blobs is Map ? blobs['voice'] : null,
      'voice',
      chunk,
      maxVoiceCiphertext,
      allowUnsent: allowUnsent,
    );
    return VoiceAttachment(
      key: _bytes(raw['key'], 'key', length: 32),
      salt: _uuid(raw['salt'], 'salt'),
      chunk: chunk,
      part: part,
      durationMs: _int(raw['dur'], 'duration', minMediaMs, maxVoiceMs),
      wave: _bytes(
        raw['wave'],
        'waveform',
        min: minWaveBytes,
        max: maxWaveBytes,
      ),
    );
  }
}

/// The decrypted `att` descriptor of a video message: the video blob, a JPEG poster blob (the same thumbnail
/// the photos use) and the tiny preview that shows before the poster arrives.
class VideoAttachment {
  final Uint8List key;
  final String salt;
  final int chunk;
  final MediaPart video, poster;

  /// Picture size of the video and of the poster.
  final int w, h, posterW, posterH;
  final int durationMs;
  final Uint8List preview;
  const VideoAttachment({
    required this.key,
    required this.salt,
    required this.chunk,
    required this.video,
    required this.poster,
    required this.w,
    required this.h,
    required this.posterW,
    required this.posterH,
    required this.durationMs,
    required this.preview,
  });

  bool get uploaded => video.blobId != null && poster.blobId != null;
  double get aspect => h == 0 ? 1 : w / h;

  VideoAttachment withBlobs({String? videoId, String? posterId}) =>
      VideoAttachment(
        key: key,
        salt: salt,
        chunk: chunk,
        video: video.withId(videoId),
        poster: poster.withId(posterId),
        w: w,
        h: h,
        posterW: posterW,
        posterH: posterH,
        durationMs: durationMs,
        preview: preview,
      );

  BlobSpec get videoSpec => BlobSpec(
    blobId: video.blobId!,
    role: 'video',
    salt: salt,
    mime: videoMime,
    key: key,
    chunk: chunk,
    plainLen: video.plainLen,
    ctSize: video.ctSize,
    ctSha256: video.ctSha256,
  );

  BlobSpec get posterSpec => BlobSpec(
    blobId: poster.blobId!,
    role: 'thumb',
    salt: salt,
    mime: attachmentMime,
    key: key,
    chunk: chunk,
    plainLen: poster.plainLen,
    ctSize: poster.ctSize,
    ctSha256: poster.ctSha256,
  );

  Map<String, dynamic> toLocalJson() => {
    'v': 1,
    'key': _b64(key),
    'salt': salt,
    'mime': videoMime,
    'chunk': chunk,
    ...video._fields(),
    if (video.blobId != null) 'blobs': {'video': video.blobId},
    'w': w,
    'h': h,
    'dur': durationMs,
    'thumb': {
      if (poster.blobId != null) 'blob': poster.blobId,
      'w': posterW,
      'h': posterH,
      ...poster._fields(),
    },
    'preview': {'t': 'thumbhash', 'd': _b64(preview)},
  };

  Map<String, dynamic> toJson() {
    assert(uploaded, 'a descriptor needs both blob ids');
    return toLocalJson();
  }

  factory VideoAttachment.fromLocal(Object? raw) =>
      VideoAttachment.parse(raw, allowUnsent: true);

  factory VideoAttachment.parse(Object? raw, {bool allowUnsent = false}) {
    if (raw is! Map) throw const FormatException('descriptor is not an object');
    if (jsonEncode(raw).length > maxDescriptorBytes) {
      throw const FormatException('descriptor is too large');
    }
    if (raw['v'] != 1) {
      throw const FormatException('unknown descriptor version');
    }
    if (raw['mime'] != videoMime) {
      throw const FormatException('unsupported type');
    }
    final chunk = _int(raw['chunk'], 'chunk', 4096, 1 << 20);
    if (chunk & (chunk - 1) != 0) throw const FormatException('bad chunk size');
    final thumb = raw['thumb'];
    if (thumb is! Map) throw const FormatException('no poster');
    final blobs = raw['blobs'];
    // Either way round: 1280 x 720 landscape or 720 x 1280 portrait.
    final w = _int(raw['w'], 'width', 1, maxVideoLongSide);
    final h = _int(raw['h'], 'height', 1, maxVideoLongSide);
    if (w > maxVideoShortSide && h > maxVideoShortSide) {
      throw const FormatException('video is too large');
    }
    final posterW = _int(thumb['w'], 'poster width', 1, maxThumbSide);
    final posterH = _int(thumb['h'], 'poster height', 1, maxThumbSide);
    final video = MediaPart._parse(
      raw,
      blobs is Map ? blobs['video'] : null,
      'video',
      chunk,
      maxVideoCiphertext,
      allowUnsent: allowUnsent,
    );
    final poster = MediaPart._parse(
      thumb,
      thumb['blob'],
      'poster',
      chunk,
      maxThumbCiphertext,
      allowUnsent: allowUnsent,
    );
    if (video.blobId != null && video.blobId == poster.blobId) {
      throw const FormatException('blobs repeat');
    }
    final preview = raw['preview'];
    if (preview is! Map || preview['t'] != 'thumbhash') {
      throw const FormatException('no preview');
    }
    return VideoAttachment(
      key: _bytes(raw['key'], 'key', length: 32),
      salt: _uuid(raw['salt'], 'salt'),
      chunk: chunk,
      video: video,
      poster: poster,
      w: w,
      h: h,
      posterW: posterW,
      posterH: posterH,
      durationMs: _int(raw['dur'], 'duration', minMediaMs, maxVideoMs),
      preview: _bytes(preview['d'], 'preview', min: 5, max: 64),
    );
  }
}

/// Reduces raw amplitude samples (0 to 1, one per sampling tick) to [waveBars] bytes: each bar is the loudest
/// sample of its slice, scaled so the loudest bar of the recording is full height (a quiet recording still
/// shows a shape), with a floor so silence is a thin line, not nothing.
Uint8List waveFromSamples(List<double> samples, {int bars = waveBars}) {
  if (samples.isEmpty) return Uint8List.fromList(List.filled(bars, 16));
  final out = List<double>.filled(bars, 0);
  for (var i = 0; i < bars; i++) {
    final from = (i * samples.length / bars).floor();
    var to = ((i + 1) * samples.length / bars).ceil();
    if (to <= from) to = from + 1;
    var peak = 0.0;
    for (var j = from; j < to && j < samples.length; j++) {
      if (samples[j] > peak) peak = samples[j];
    }
    out[i] = peak.clamp(0.0, 1.0);
  }
  final loudest = out.reduce((a, b) => a > b ? a : b);
  final scale = loudest < .05 ? 1.0 : 1 / loudest;
  return Uint8List.fromList([
    for (final v in out) (16 + (v * scale) * 239).round().clamp(16, 255),
  ]);
}

/// "0:07" or "1:23": the length of a recording or a video, rounded to the nearest second.
String clockOf(int milliseconds) {
  final total = (milliseconds / 1000).round();
  final m = total ~/ 60, s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
