// Package logscrub keeps URLs out of log lines. Go's network errors quote the full URL they were fetching,
// and a presigned storage URL carries its signature in the query string.
package logscrub

import "regexp"

var urlInText = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"']+`)

// URLs replaces every URL inside s with "[url]".
func URLs(s string) string { return urlInText.ReplaceAllString(s, "[url]") }

// Err is URLs(err.Error()) for an error that is not nil.
func Err(err error) string {
	if err == nil {
		return ""
	}
	return URLs(err.Error())
}
