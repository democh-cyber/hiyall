package media

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// gradient makes a photo-like image: smooth, with a diagonal edge so its difference hash is not trivial.
func gradient(w, h int, shift int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			v := uint8((x*255/w + (y*(x+shift))/h) % 256)
			img.Set(x, y, color.RGBA{v, uint8(255 - int(v)), uint8(x * 255 / w), 255})
		}
	}
	var buf bytes.Buffer
	_ = jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90})
	return buf.Bytes()
}

func writeList(t *testing.T, lines ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "hashes.txt")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNoneIsAlwaysClean(t *testing.T) {
	r, err := None{}.Scan(context.Background(), ScanInput{})
	if err != nil || r.Verdict != Clean || r.Scanner != "none" {
		t.Fatal(r, err)
	}
}

func TestHashListMatchesExactDigestsOfTheUploadOrTheReencode(t *testing.T) {
	original, full := gradient(200, 150, 0), gradient(160, 120, 3)
	list, err := NewHashList(writeList(t, "# operator list", "", "sha256:"+SHA256Hex(original)+" batch-7", SHA256Hex(full)+" "))
	if err != nil || list.Len() != 2 {
		t.Fatal(list, err)
	}
	for name, in := range map[string]ScanInput{
		"original":  {Original: original, Full: gradient(10, 10, 9)},
		"processed": {Original: gradient(11, 11, 4), Full: full},
	} {
		r, err := list.Scan(context.Background(), in)
		if err != nil || r.Verdict != Match || r.Signals["kind"] != "sha256" {
			t.Fatalf("%s: %+v %v", name, r, err)
		}
	}
	if r, _ := list.Scan(context.Background(), ScanInput{Original: gradient(30, 30, 1), Full: gradient(30, 30, 1)}); r.Verdict != Clean {
		t.Fatalf("unlisted photo: %+v", r)
	}
	if r, _ := list.Scan(context.Background(), ScanInput{Original: original}); r.Signals["label"] != "batch-7" {
		t.Fatalf("label not recorded: %+v", r)
	}
}

func TestHashListPerceptualMatchSurvivesReencodingAndFlagsNearHashes(t *testing.T) {
	known := gradient(256, 192, 0)
	hash, err := PerceptualHash(known)
	if err != nil {
		t.Fatal(err)
	}
	list, err := NewHashList(writeList(t, "phash:"+hex16(hash)+" known-1"))
	if err != nil {
		t.Fatal(err)
	}
	// The same picture, smaller and at another quality, is still a match.
	small, _ := Process(known)
	r, err := list.Scan(context.Background(), ScanInput{Original: []byte("not the same bytes"), Full: small.Thumb})
	if err != nil || r.Verdict != Match || r.Signals["label"] != "known-1" {
		t.Fatalf("re-encoded copy: %+v %v", r, err)
	}
	// Distances between the thresholds are flagged, beyond them clean.
	for _, c := range []struct {
		flip int
		want Verdict
	}{{3, Match}, {6, Flagged}, {20, Clean}} {
		// flip sets the number of differing bits: the low `flip` bits of the listed hash are inverted.
		l, _ := NewHashList(writeList(t, "phash:"+hex16(hash^(1<<uint(c.flip)-1))))
		got, _ := l.Scan(context.Background(), ScanInput{Full: known})
		if got.Verdict != c.want {
			t.Fatalf("flip %d bits: %s want %s (%v)", c.flip, got.Verdict, c.want, got.Signals)
		}
	}
}

func hex16(n uint64) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 16)
	for i := 15; i >= 0; i-- {
		out[i] = digits[n&15]
		n >>= 4
	}
	return string(out)
}

func TestHashListRejectsBadFilesAndReloads(t *testing.T) {
	if _, err := NewHashList(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing file accepted")
	}
	if _, err := NewHashList(writeList(t, "not a hash")); err == nil || !strings.Contains(err.Error(), "line 1") {
		t.Fatal(err)
	}
	path := writeList(t, "# empty")
	list, _ := NewHashList(path)
	clock := time.Now()
	list.now = func() time.Time { return clock }
	photo := gradient(64, 64, 0)
	if r, _ := list.Scan(context.Background(), ScanInput{Original: photo}); r.Verdict != Clean {
		t.Fatal(r)
	}
	if err := os.WriteFile(path, []byte(SHA256Hex(photo)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Hour)
	_ = os.Chtimes(path, future, future)
	clock = clock.Add(time.Minute)
	if r, _ := list.Scan(context.Background(), ScanInput{Original: photo}); r.Verdict != Match {
		t.Fatalf("list not reloaded: %+v", r)
	}
	// A bad update keeps the previous list.
	_ = os.WriteFile(path, []byte("garbage\n"), 0o600)
	later := future.Add(time.Hour)
	_ = os.Chtimes(path, later, later)
	clock = clock.Add(time.Minute)
	if r, _ := list.Scan(context.Background(), ScanInput{Original: photo}); r.Verdict != Match {
		t.Fatalf("a broken update emptied the list: %+v", r)
	}
}

type stub struct {
	r   ScanResult
	err error
}

func (s stub) Name() string { return "stub" }
func (s stub) Scan(context.Context, ScanInput) (ScanResult, error) {
	return s.r, s.err
}

func TestChainTakesTheWorstVerdictAndFailsClosed(t *testing.T) {
	in := ScanInput{}
	c := Chain{stub{r: ScanResult{Verdict: Clean}}, stub{r: ScanResult{Verdict: Flagged, Scanner: "b"}}, stub{r: ScanResult{Verdict: Clean}}}
	if r, err := c.Scan(context.Background(), in); err != nil || r.Verdict != Flagged || r.Scanner != "b" {
		t.Fatal(r, err)
	}
	c = append(c, stub{r: ScanResult{Verdict: Match, Scanner: "c"}}, stub{err: errors.New("never reached")})
	if r, _ := c.Scan(context.Background(), in); r.Verdict != Match || r.Scanner != "c" {
		t.Fatal(r)
	}
	if _, err := (Chain{stub{r: ScanResult{Verdict: Clean}}, stub{err: errors.New("down")}}).Scan(context.Background(), in); err == nil {
		t.Fatal("a failing scanner let the photo through")
	}
}

func TestHTTPProviderSendsTheJPEGWithTheKeyAndReadsTheVerdict(t *testing.T) {
	var gotAuth, gotType string
	var gotBody []byte
	answer := `{"verdict":"match","reference":"case-123"}`
	status := 200
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotType = r.Header.Get("Authorization"), r.Header.Get("Content-Type")
		gotBody = make([]byte, r.ContentLength)
		_, _ = r.Body.Read(gotBody)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(answer))
	}))
	defer server.Close()
	keyFile := filepath.Join(t.TempDir(), "key")
	_ = os.WriteFile(keyFile, []byte("secret-key\n"), 0o600)
	p, err := NewHTTPProvider(server.URL, keyFile, false)
	if err != nil {
		t.Fatal(err)
	}
	full := gradient(50, 50, 0)
	r, err := p.Scan(context.Background(), ScanInput{Original: []byte("original must not be sent"), Full: full})
	if err != nil || r.Verdict != Match || r.Signals["reference"] != "case-123" {
		t.Fatal(r, err)
	}
	if gotAuth != "Bearer secret-key" || gotType != "application/octet-stream" || !bytes.Equal(gotBody, full) {
		t.Fatalf("request %q %q %d bytes", gotAuth, gotType, len(gotBody))
	}
	for name, c := range map[string]struct {
		status int
		body   string
	}{"server error": {500, "{}"}, "unknown verdict": {200, `{"verdict":"maybe"}`}, "not json": {200, "ok"}} {
		status, answer = c.status, c.body
		if _, err := p.Scan(context.Background(), ScanInput{Full: full}); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	if _, err := NewHTTPProvider("http://example.test/scan", keyFile, true); err == nil {
		t.Fatal("plain http accepted in production")
	}
	if _, err := NewHTTPProvider(server.URL, filepath.Join(t.TempDir(), "none"), false); err == nil {
		t.Fatal("missing key file accepted")
	}
	if _, err := NewHTTPProvider("https://user:pw@example.test/", keyFile, true); err == nil {
		t.Fatal("credentials in the URL accepted")
	}
}

func TestHoldKeysStayOutsideTheDisplayPrefix(t *testing.T) {
	o, f := HoldKeys("abc")
	if !strings.HasPrefix(o, HoldPrefix+"abc/") || !strings.HasPrefix(f, HoldPrefix+"abc/") || strings.HasPrefix(o, "media/") {
		t.Fatal(o, f)
	}
}
