/// What a profile may hold. The server enforces every one of these (and a plan may raise some later: the
/// gallery's real size comes back as [Gallery.max]); the app uses them for counters and to stop early.
const maxProfileLanguages = 5;
const maxProfileInterests = 10;
const maxAboutMe = 160;

/// A hometown or city is coarse free text, never an address. A member under 18 writes at most
/// [maxMinorHometown] characters.
const maxHometown = 80;
const maxMinorHometown = 40;

/// The gallery size until the server says otherwise.
const defaultMaxPhotos = 8;

/// Whether [text] looks like a street address rather than a town or a city: more than two digits, an address
/// word, or one of # @ / :. The server refuses the same, so this only saves a round trip.
bool looksLikeAddress(String text) {
  var digits = 0;
  for (final unit in text.runes) {
    if (unit >= 0x30 && unit <= 0x39) digits++;
  }
  return digits > 2 ||
      text.contains(RegExp('[#@/:]')) ||
      RegExp(
        r'\b(street|road|avenue|lane|boulevard|apartment|apt|flat|house|plot|sector|floor|p\.?o\.? box)\b',
        caseSensitive: false,
      ).hasMatch(text);
}
