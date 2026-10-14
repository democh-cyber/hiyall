package domain

import (
	"strconv"
	"strings"
)

// ParseClientVersion reads an app version as sent in X-Client-Version: "MAJOR.MINOR.PATCH", allowing a
// missing minor or patch, a leading "v", and a pre-release or build suffix, which is ignored (1.4.0-beta.2+77
// compares as 1.4.0).
func ParseClientVersion(s string) ([3]int, bool) {
	var v [3]int
	s = strings.TrimPrefix(strings.TrimSpace(s), "v")
	if i := strings.IndexAny(s, "-+"); i >= 0 {
		s = s[:i]
	}
	if s == "" || len(s) > 32 {
		return v, false
	}
	parts := strings.Split(s, ".")
	if len(parts) > 3 {
		return v, false
	}
	for i, part := range parts {
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 || n > 1_000_000 || part != strconv.Itoa(n) {
			return v, false
		}
		v[i] = n
	}
	return v, true
}

// ClientVersionLess reports whether a is older than b.
func ClientVersionLess(a, b [3]int) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}
