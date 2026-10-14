// Text from a peer is data: it can carry characters that reorder or hide what
// a bubble says (a right-to-left override that makes "gnp.exe" read as
// "exe.png", zero-width characters that hide a word). These helpers make it
// safe to draw.

bool _invisible(int c) =>
    (c <= 0x08) ||
    c == 0x0B ||
    c == 0x0C ||
    (c >= 0x0E && c <= 0x1F) ||
    (c >= 0x7F && c <= 0x9F) ||
    c == 0x061C || // Arabic letter mark
    c == 0x180E ||
    c == 0x200B || // zero-width space
    c == 0x200E || // left-to-right mark
    c == 0x200F || // right-to-left mark
    (c >= 0x202A && c <= 0x202E) || // embeddings and overrides
    (c >= 0x2060 && c <= 0x2064) || // word joiner, invisible operators
    (c >= 0x2066 && c <= 0x2069) || // isolates
    (c >= 0x206A && c <= 0x206F) || // deprecated format characters
    c == 0xFEFF ||
    (c >= 0xFFF9 && c <= 0xFFFB);

/// [text] without bidirectional controls, zero-width characters and control
/// characters. Line breaks and tabs stay. The zero-width joiner and non-joiner
/// stay as well: emoji sequences and several scripts need them.
String displayText(String text) {
  var clean = true;
  for (final c in text.runes) {
    if (_invisible(c)) {
      clean = false;
      break;
    }
  }
  if (clean) return text;
  return String.fromCharCodes(text.runes.where((c) => !_invisible(c)));
}
