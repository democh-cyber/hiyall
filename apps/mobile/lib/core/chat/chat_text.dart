import 'chat_unicode_tables.dart';

// Chat text rules: the app's twin of the API's text rules
// (services/api/internal/domain/text.go), which cannot see a chat message
// because it is end-to-end encrypted. Both sides run the same shared test
// vectors (services/api/internal/domain/testdata/text_vectors.json).
//
// A text is clean if it is valid UTF-16 and holds:
//  * no control characters (Cc) other than tab, line feed and carriage return
//    when it may span lines;
//  * no format characters (Cf: bidirectional overrides, embeddings and
//    isolates, zero-width spaces, word joiners, byte order mark, soft hyphen,
//    tag characters) except the zero width joiner and non-joiner, and those
//    only between two other characters, never first, last, doubled or next to
//    a space;
//  * no private-use characters (Co) and no line or paragraph separators;
//  * at most [maxCombiningRun] combining marks (Mn, Me) in a row.
// Text this app sends is normalised to NFC. Text it receives is cleaned the
// same way before it is shown or stored: what breaks the rules is removed,
// never rejected, because the sender's app is not under our control.

/// The longest run of combining marks that is accepted.
const maxCombiningRun = 5;

bool _lonePart(int c) => c >= 0xD800 && c <= 0xDFFF;

bool _inRanges(int c, List<int> pairs) {
  var lo = 0, hi = pairs.length ~/ 2 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (c < pairs[mid * 2]) {
      hi = mid - 1;
    } else if (c > pairs[mid * 2 + 1]) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

bool _isControl(int c) => c < 0x20 || (c >= 0x7F && c <= 0x9F);
bool _isPrivate(int c) =>
    (c >= 0xE000 && c <= 0xF8FF) ||
    (c >= 0xF0000 && c <= 0xFFFFD) ||
    (c >= 0x100000 && c <= 0x10FFFD);
bool _isFormat(int c) => c >= 0xAD && _inRanges(c, unicodeCfRanges);
bool _isMark(int c) => c >= 0x300 && _inRanges(c, unicodeMarkRanges);
bool _isJoiner(int c) => c == 0x200C || c == 0x200D;

/// Go's `unicode.IsSpace`.
bool _isSpace(int c) =>
    c == 0x20 ||
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

bool _lineBreakChar(int c) => c == 0x09 || c == 0x0A || c == 0x0D;

/// Whether the joiner at [i] has a visible character on both sides.
bool _joinerInside(List<int> runes, int i) {
  if (i == 0 || i == runes.length - 1) return false;
  for (final n in [runes[i - 1], runes[i + 1]]) {
    if (_isSpace(n) || _isFormat(n) || _isControl(n)) return false;
  }
  return true;
}

/// True when every code unit is plain enough that nothing needs checking:
/// printable ASCII, tab, line feed, carriage return, and Latin letters below
/// U+0300 (all of which are already in NFC).
bool _plain(String s, bool multiline) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u >= 0x20 && u < 0x7F) continue;
    if (u >= 0xA0 && u < 0x300 && u != 0xAD && u != 0x85) continue;
    if (multiline && _lineBreakChar(u)) continue;
    return false;
  }
  return true;
}

/// Whether [s] follows the rules above (the twin of Go's `CleanText`, or
/// `CleanLine` when [multiline] is false). Does not look at normalisation.
bool isCleanText(String s, {bool multiline = true}) {
  if (_plain(s, multiline)) return true;
  final runes = s.runes.toList(growable: false);
  var marks = 0;
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (_lonePart(r)) return false;
    if (_lineBreakChar(r)) {
      if (!multiline) return false;
    } else if (r == 0x2028 || r == 0x2029 || _isControl(r) || _isPrivate(r)) {
      return false;
    } else if (_isFormat(r)) {
      if (!_isJoiner(r) || !_joinerInside(runes, i)) return false;
    }
    if (_isMark(r)) {
      if (++marks > maxCombiningRun) return false;
    } else {
      marks = 0;
    }
  }
  return true;
}

/// [s] in Unicode normalisation form C (the twin of Go's `Normalize`).
String normalizeNfc(String s) {
  var simple = true;
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) >= 0x300) {
      simple = false;
      break;
    }
  }
  if (simple) return s;
  final out = String.fromCharCodes(_nfc(s.runes));
  return out == s ? s : out;
}

List<int> _nfc(Iterable<int> runes) {
  final decomposed = <int>[];
  for (final r in runes) {
    _decompose(r, decomposed);
  }
  _reorder(decomposed);
  return _compose(decomposed);
}

/// Where a well-formed emoji tag sequence that starts at [i] ends (exclusive),
/// or [i] when there is none. The subdivision flags (England, Scotland,
/// Wales) are a waving black flag, tag letters or digits (Cf characters
/// U+E0020 to U+E007E) and a cancel tag U+E007F. The API's rules would remove
/// every tag character; chat keeps these sequences, since they are emoji people
/// send, and nothing else in the tag block (which is also used to smuggle
/// invisible text). [isCleanText] stays as strict as the API.
int _emojiTagsEnd(List<int> runes, int i) {
  if (i == 0 || runes[i - 1] != 0x1F3F4) return i;
  var j = i;
  while (j < runes.length && runes[j] >= 0xE0020 && runes[j] <= 0xE007E) {
    j++;
  }
  final letters = j - i;
  return letters >= 2 && letters <= 8 && j < runes.length && runes[j] == 0xE007F
      ? j + 1
      : i;
}

/// What the app does to text it is about to send, and to text it received
/// before showing it or keeping it: NFC, then everything the rules forbid
/// removed (a lone surrogate, controls, private-use and invisible format
/// characters, stray joiners, marks beyond [maxCombiningRun] in a row).
/// Line breaks and tabs stay unless [multiline] is false. Returns [s] itself
/// when nothing changed.
String sanitizeText(String s, {bool multiline = true}) {
  if (_plain(s, multiline)) return s;
  // Lone surrogates go first: a string cannot hold them through [_nfc].
  final runes = _nfc([
    for (final r in s.runes)
      if (!_lonePart(r)) r,
  ]);
  final kept = <int>[];
  var marks = 0;
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    final tagsEnd = _emojiTagsEnd(runes, i);
    if (tagsEnd > i) {
      // The England, Scotland and Wales flags: kept whole (see [_emojiTagsEnd]).
      kept.addAll(runes.getRange(i, tagsEnd));
      i = tagsEnd - 1;
      marks = 0;
      continue;
    }
    if (_lonePart(r) || r == 0x2028 || r == 0x2029) continue;
    if (_lineBreakChar(r)) {
      if (multiline) {
        kept.add(r);
        marks = 0;
      }
      continue;
    }
    if (_isControl(r) || _isPrivate(r)) continue;
    if (_isFormat(r) && !_isJoiner(r)) continue;
    if (_isMark(r)) {
      if (marks >= maxCombiningRun) continue;
      marks++;
    } else {
      marks = 0;
    }
    kept.add(r);
  }
  final cleaned = <int>[];
  for (var i = 0; i < kept.length; i++) {
    if (_isJoiner(kept[i]) && !_joinerInside(kept, i)) continue;
    cleaned.add(kept[i]);
  }
  final stripped = cleaned.length == runes.length;
  // Removing a character can bring two others together that compose.
  var out = String.fromCharCodes(stripped ? cleaned : _nfc(cleaned));
  return out == s ? s : out;
}

/// [text] without anything the rules forbid, for drawing (see [sanitizeText]).
String displayText(String text) => sanitizeText(text);

// --------------------------------------------------------- normalisation

Map<int, List<int>>? _decompositionIndex;
Map<int, int>? _compositionIndex;

Map<int, List<int>> get _decomps {
  var index = _decompositionIndex;
  if (index != null) return index;
  index = <int, List<int>>{};
  final t = unicodeDecompositions;
  for (var i = 0; i < t.length;) {
    final n = t[i + 1];
    index[t[i]] = t.sublist(i + 2, i + 2 + n);
    i += 2 + n;
  }
  return _decompositionIndex = index;
}

Map<int, int> get _comps {
  var index = _compositionIndex;
  if (index != null) return index;
  index = <int, int>{};
  final t = unicodeCompositions;
  for (var i = 0; i < t.length; i += 3) {
    index[t[i] * 0x110000 + t[i + 1]] = t[i + 2];
  }
  return _compositionIndex = index;
}

int _ccc(int c) {
  if (c < 0x300) return 0;
  final t = unicodeCccRanges;
  var lo = 0, hi = t.length ~/ 3 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (c < t[mid * 3]) {
      hi = mid - 1;
    } else if (c > t[mid * 3 + 1]) {
      lo = mid + 1;
    } else {
      return t[mid * 3 + 2];
    }
  }
  return 0;
}

const _sBase = 0xAC00,
    _lBase = 0x1100,
    _vBase = 0x1161,
    _tBase = 0x11A7,
    _lCount = 19,
    _vCount = 21,
    _tCount = 28,
    _nCount = _vCount * _tCount,
    _sCount = _lCount * _nCount;

void _decompose(int c, List<int> out) {
  if (c < 0x80) {
    out.add(c);
    return;
  }
  if (c >= _sBase && c < _sBase + _sCount) {
    final s = c - _sBase;
    out.add(_lBase + s ~/ _nCount);
    out.add(_vBase + (s % _nCount) ~/ _tCount);
    final t = s % _tCount;
    if (t != 0) out.add(_tBase + t);
    return;
  }
  final d = _decomps[c];
  if (d == null) {
    out.add(c);
  } else {
    out.addAll(d);
  }
}

/// Canonical ordering: marks sort by combining class, stably.
void _reorder(List<int> text) {
  for (var i = 1; i < text.length; i++) {
    final c = _ccc(text[i]);
    if (c == 0) continue;
    var j = i;
    while (j > 0) {
      final before = _ccc(text[j - 1]);
      if (before <= c) break;
      final swap = text[j];
      text[j] = text[j - 1];
      text[j - 1] = swap;
      j--;
    }
  }
}

int? _pair(int a, int b) {
  if (a >= _lBase &&
      a < _lBase + _lCount &&
      b >= _vBase &&
      b < _vBase + _vCount) {
    return _sBase + ((a - _lBase) * _vCount + (b - _vBase)) * _tCount;
  }
  if (a >= _sBase &&
      a < _sBase + _sCount &&
      (a - _sBase) % _tCount == 0 &&
      b > _tBase &&
      b < _tBase + _tCount) {
    return a + (b - _tBase);
  }
  return _comps[a * 0x110000 + b];
}

/// The composition algorithm of UAX #15 over canonically ordered text.
List<int> _compose(List<int> text) {
  if (text.isEmpty) return text;
  final out = <int>[text.first];
  var starter = 0;
  var lastClass = _ccc(text.first);
  if (lastClass != 0) lastClass = 256; // text that opens with a mark
  for (var i = 1; i < text.length; i++) {
    final ch = text[i];
    final chClass = _ccc(ch);
    final composite = _pair(out[starter], ch);
    if (composite != null && (lastClass < chClass || lastClass == 0)) {
      out[starter] = composite;
    } else {
      if (chClass == 0) starter = out.length;
      lastClass = chClass;
      out.add(ch);
    }
  }
  return out;
}
