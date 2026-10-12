import 'package:flutter/material.dart';

/// Pairs of mid-light colours for avatars without a photo. All of them are
/// light enough for the dark initial on top of them to pass WCAG AA at every
/// point of the gradient (see `chat_tokens_test.dart`).
const avatarPalettes = <(Color, Color)>[
  (Color(0xffc9b3fb), Color(0xffff9ec9)),
  (Color(0xff9fe3c8), Color(0xffd6f26a)),
  (Color(0xffffb98f), Color(0xfff29bc3)),
  (Color(0xffb6a4f7), Color(0xff8fdcd0)),
  (Color(0xffd2f65a), Color(0xff8fe0c0)),
  (Color(0xffffc59f), Color(0xffc9b3fb)),
  (Color(0xff9fd4f2), Color(0xffc9b3fb)),
  (Color(0xffffa996), Color(0xffffcf8a)),
  (Color(0xffbfe38f), Color(0xff9fd4f2)),
  (Color(0xfff2a6d8), Color(0xffa9b8fb)),
];

/// A stable 32-bit hash (FNV-1a) of [seed]. `String.hashCode` is not stable
/// across runs, and a person's colours must not change between launches.
int stableHash(String seed) {
  var h = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// The colours of the gradient for [seed] (a user id; a name when there is
/// none). The same seed gives the same colours on every screen and every run.
(Color, Color) avatarColors(String seed) =>
    avatarPalettes[stableHash(seed) % avatarPalettes.length];

/// The avatar fill for [seed]: its palette on one of four diagonals.
LinearGradient avatarGradient(String seed) {
  final h = stableHash(seed);
  final (a, b) = avatarPalettes[h % avatarPalettes.length];
  const starts = [
    Alignment.topLeft,
    Alignment.topRight,
    Alignment.centerLeft,
    Alignment.topCenter,
  ];
  final begin = starts[(h >> 8) % starts.length];
  return LinearGradient(begin: begin, end: -begin, colors: [a, b]);
}
