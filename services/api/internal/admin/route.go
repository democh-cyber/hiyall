package admin

import (
	"regexp"
	"strings"
)

var idSegment = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// adminRoute turns a request path into a loggable pattern: identifiers become ":id" and anything
// that is not a plain word becomes ":x", so a log line never carries a member's or report's id.
func adminRoute(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) > 8 {
		return "other"
	}
	for i, p := range parts {
		switch {
		case idSegment.MatchString(p):
			parts[i] = ":id"
		case len(p) > 32 || strings.Trim(p, "abcdefghijklmnopqrstuvwxyz0123456789-_") != "":
			parts[i] = ":x"
		}
	}
	return "/" + strings.Join(parts, "/")
}
