package domain

import (
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// Text rules for every free-text field (display names, bios, headlines, interests, posts, comments,
// stories, spaces). A value is accepted only if it is valid UTF-8 and holds:
//
//   - no control characters (Cc: C0, DEL and C1) other than tab, line feed and carriage return where the
//     field may span lines. NUL in particular can never be stored: PostgreSQL text and jsonb reject it;
//   - no format characters (Cf): bidi overrides, embeddings and isolates, zero-width spaces, word
//     joiners, the byte order mark, soft hyphen, tag characters. The exceptions are the zero width joiner
//     U+200D (emoji sequences, Indic conjuncts) and the zero width non-joiner U+200C (Persian and Indic
//     spelling), each only between two other characters, never first, last, doubled or next to a space;
//   - no private-use characters (Co) and no line or paragraph separators (U+2028, U+2029);
//   - at most MaxCombiningRun combining marks (Mn, Me) in a row, which stops stacked "zalgo" text and
//     still allows emoji variation selectors, accents, Arabic vowel marks and Indic scripts.
//
// Accepted text is stored in Unicode normalisation form C (see Normalize), so the same name typed two
// ways is one name. Callers normalise first (Normalize) and then check lengths and cleanliness.

// MaxCombiningRun is the longest run of combining marks accepted.
const MaxCombiningRun = 5

// Normalize returns s in NFC. Invalid UTF-8 is returned unchanged (and fails CleanText).
func Normalize(s string) string {
	if !utf8.ValidString(s) {
		return s
	}
	return norm.NFC.String(s)
}

// CleanText reports whether s is acceptable multi-line text (see the rules above); tab, line feed and
// carriage return are allowed.
func CleanText(s string) bool { return clean(s, true) }

// CleanLine is CleanText for one-line values (names, interests, filters): no tab or line break either.
func CleanLine(s string) bool { return clean(s, false) }

func clean(s string, multiline bool) bool {
	if !utf8.ValidString(s) {
		return false
	}
	runes := []rune(s)
	marks := 0
	for i, r := range runes {
		switch {
		case r == '\t' || r == '\n' || r == '\r':
			if !multiline {
				return false
			}
		case r == 0x2028 || r == 0x2029:
			return false
		case unicode.Is(unicode.Cc, r), unicode.Is(unicode.Co, r):
			return false
		case unicode.Is(unicode.Cf, r):
			if (r != 0x200D && r != 0x200C) || !joinerInside(runes, i) {
				return false
			}
		}
		if unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) {
			marks++
			if marks > MaxCombiningRun {
				return false
			}
		} else {
			marks = 0
		}
	}
	return true
}

// joinerInside is true when the joiner at i has a visible character on both sides: not first or last, not
// next to another joiner, a space or a line break.
func joinerInside(runes []rune, i int) bool {
	if i == 0 || i == len(runes)-1 {
		return false
	}
	for _, n := range []rune{runes[i-1], runes[i+1]} {
		if unicode.IsSpace(n) || unicode.Is(unicode.Cf, n) || unicode.Is(unicode.Cc, n) {
			return false
		}
	}
	return true
}
