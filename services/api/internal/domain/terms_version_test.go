package domain

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// The accepted terms version is recorded per account, so the text a person agrees to
// must be the revision the server asks for. Every legal draft starts with a
// "Version:" line; they must all equal TermsVersion (the app mirrors it in
// kTermsVersion and tests the bundled copies the same way).
func TestLegalDocumentsCarryTheServersTermsVersion(t *testing.T) {
	files, err := filepath.Glob("../../../../docs/legal/*.md")
	if err != nil || len(files) < 5 {
		t.Fatalf("docs/legal documents not found: %v %v", files, err)
	}
	version := regexp.MustCompile(`(?m)^Version:[ \t]*(\S+)[ \t]*$`)
	for _, file := range files {
		raw, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		m := version.FindSubmatch(raw)
		if m == nil {
			t.Errorf("%s has no Version: line", filepath.Base(file))
			continue
		}
		if string(m[1]) != TermsVersion {
			t.Errorf("%s is version %s but domain.TermsVersion is %s: bump them together", filepath.Base(file), m[1], TermsVersion)
		}
	}
}
