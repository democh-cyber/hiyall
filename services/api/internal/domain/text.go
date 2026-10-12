package domain

import "unicode/utf8"

// CleanText reports whether s is valid UTF-8 without control characters other than
// tab, line feed and carriage return. NUL in particular can never be stored:
// PostgreSQL text and jsonb reject it. Every free-text field goes through this or
// CleanLine, so such input is a 422 and never reaches the database.
func CleanText(s string) bool { return clean(s, true) }

// CleanLine is CleanText for one-line values (interests, filters): no tab or line break either.
func CleanLine(s string) bool { return clean(s, false) }

func clean(s string, multiline bool) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			if multiline && (r == '\t' || r == '\n' || r == '\r') {
				continue
			}
			return false
		}
	}
	return true
}
