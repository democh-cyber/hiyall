package media

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"io"
	"log/slog"
	"math/bits"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/disintegration/imaging"

	"hiyall/services/api/internal/metrics"
)

// Upload scanning (docs/security/16-csam-and-illegal-content.md). Every photo that is NOT end-to-end
// encrypted (avatars, posts, stories) is scanned after it has been decoded and re-encoded and before it
// can be attached or shown. The scanner never decides what happens next: it only answers clean, flagged
// or match. The caller quarantines, suspends and opens a case; nothing here ever sends an image, a hash or
// a verdict to a third party except the HTTP provider the operator configured on purpose.

// Verdict is a scanner's answer.
type Verdict string

const (
	// Clean: nothing found. The photo goes on to be ready.
	Clean Verdict = "clean"
	// Flagged: possible but not certain (a near hash, a provider score). Quarantined for a person to
	// look at, the uploader is not suspended.
	Flagged Verdict = "flagged"
	// Match: a STRONG match only: the SHA-256 of the exact file is on the list, or the provider says match.
	// Quarantined, uploader suspended pending review. A perceptual hash alone is never a Match: it is a
	// 64-bit fingerprint that unrelated photos (flat skies, screenshots, dark rooms) can come close to, so
	// suspending an account on it would punish the innocent (audit SAFE-1).
	Match Verdict = "match"
)

func (v Verdict) rank() int {
	switch v {
	case Match:
		return 2
	case Flagged:
		return 1
	}
	return 0
}

// ScanInput is one upload. Original is the bytes the client uploaded (before re-encoding); Full is the
// re-encoded, metadata-free JPEG that would be served.
type ScanInput struct {
	Original, Full []byte
}

// ScanResult is a verdict plus the non-image signals behind it (list name, provider reference, hash
// distance). Signals are stored with the case and must never hold image bytes.
type ScanResult struct {
	Verdict Verdict
	Scanner string
	Signals map[string]string
}

// Scanner inspects an upload. An error means "could not tell": the caller must not make the photo
// visible (fail closed).
type Scanner interface {
	Name() string
	Scan(ctx context.Context, in ScanInput) (ScanResult, error)
}

// None is the development scanner: everything is clean. Production refuses to start with it unless
// SCAN_ALLOW_NONE=true is set (see config).
type None struct{}

func (None) Name() string { return "none" }
func (None) Scan(context.Context, ScanInput) (ScanResult, error) {
	return ScanResult{Verdict: Clean, Scanner: "none"}, nil
}

// Chain runs scanners in order and returns the most severe verdict (a Match ends the run). An error from
// any scanner is an error: a scanner that is down must not let photos through.
type Chain []Scanner

func (c Chain) Name() string {
	names := make([]string, len(c))
	for i, s := range c {
		names[i] = s.Name()
	}
	return strings.Join(names, "+")
}

func (c Chain) Scan(ctx context.Context, in ScanInput) (ScanResult, error) {
	worst := ScanResult{Verdict: Clean, Scanner: c.Name()}
	for _, s := range c {
		r, err := s.Scan(ctx, in)
		if err != nil {
			return ScanResult{}, err
		}
		if r.Verdict.rank() > worst.Verdict.rank() {
			worst = r
		}
		if worst.Verdict == Match {
			break
		}
	}
	return worst, nil
}

// ---- hash list

// HashList matches uploads against a list the operator supplies (never committed to the repository):
// SHA-256 digests of exact files, and optionally 64-bit perceptual hashes (a difference hash, see
// PerceptualHash) compared by Hamming distance. List format, one entry per line, "#" starts a comment,
// anything after the first space is a label that is recorded with a match:
//
//	sha256:<64 hex>   [label]       or a bare 64 hex digits
//	phash:<16 hex>    [label]       or a bare 16 hex digits
//
// An exact SHA-256 hit is a Match (strong). A perceptual hash within FlagDistance is only Flagged, however
// close (signal strength=perceptual): the photo is quarantined and a case opened for a person, nobody is
// suspended. Perceptual entries need entropy (MinPerceptualBits to MaxPerceptualBits set bits): an all-zero
// or all-one hash is what a flat image produces and would flag half the internet, so such entries are
// rejected at load and counted in the log. The list is re-read when the file changes (checked at most every
// 30 seconds), so an update needs no restart.
type HashList struct {
	Path         string
	FlagDistance int // default 8

	mu       sync.Mutex
	checked  time.Time
	mtime    time.Time
	sha      map[string]string
	phash    []phashEntry
	rejected int
	now      func() time.Time
}

// A perceptual entry must have between MinPerceptualBits and MaxPerceptualBits bits set (of 64).
const (
	MinPerceptualBits = 12
	MaxPerceptualBits = 52
)

type phashEntry struct {
	hash  uint64
	label string
}

// NewHashList loads the file once; an unreadable or malformed list is an error, so a bad path stops the
// server at start instead of silently scanning nothing.
func NewHashList(path string) (*HashList, error) {
	h := &HashList{Path: path, FlagDistance: 8, now: time.Now}
	if err := h.load(); err != nil {
		return nil, err
	}
	return h, nil
}

func (h *HashList) Name() string { return "hashlist" }

// Len is the number of entries (digests plus perceptual hashes).
func (h *HashList) Len() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.sha) + len(h.phash)
}

// Rejected is how many perceptual entries the last load refused for too little entropy.
func (h *HashList) Rejected() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.rejected
}

func (h *HashList) load() error {
	f, err := os.Open(h.Path)
	if err != nil {
		return errors.New("SCAN_HASHLIST_FILE cannot be read")
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return errors.New("SCAN_HASHLIST_FILE cannot be read")
	}
	sha := map[string]string{}
	var ph []phashEntry
	rejected := 0
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		field, label, _ := strings.Cut(text, " ")
		label = strings.TrimSpace(label)
		kind, value, hasKind := strings.Cut(field, ":")
		if !hasKind {
			kind, value = "", field
		}
		value = strings.ToLower(value)
		raw, err := hex.DecodeString(value)
		switch {
		case err == nil && len(raw) == 32 && (kind == "" || kind == "sha256"):
			sha[value] = label
		case err == nil && len(raw) == 8 && (kind == "" || kind == "phash"):
			var n uint64
			for _, b := range raw {
				n = n<<8 | uint64(b)
			}
			if ones := bits.OnesCount64(n); ones < MinPerceptualBits || ones > MaxPerceptualBits {
				rejected++
				continue
			}
			ph = append(ph, phashEntry{hash: n, label: label})
		default:
			return fmt.Errorf("SCAN_HASHLIST_FILE line %d is not a sha256 or phash entry", line)
		}
	}
	if err := scanner.Err(); err != nil {
		return errors.New("SCAN_HASHLIST_FILE cannot be read")
	}
	h.mu.Lock()
	h.sha, h.phash, h.mtime, h.checked, h.rejected = sha, ph, info.ModTime(), h.now(), rejected
	h.mu.Unlock()
	if rejected > 0 {
		slog.Warn("hash list: perceptual entries rejected for too little entropy (flat or near-flat hashes match unrelated photos)", "rejected", rejected, "kept", len(ph), "minBits", MinPerceptualBits, "maxBits", MaxPerceptualBits)
	}
	return nil
}

// refresh reloads the list when the file changed. A failed reload keeps the previous list.
func (h *HashList) refresh() {
	h.mu.Lock()
	due := h.now().Sub(h.checked) >= 30*time.Second
	if due {
		h.checked = h.now()
	}
	last := h.mtime
	h.mu.Unlock()
	if !due {
		return
	}
	if info, err := os.Stat(h.Path); err == nil && !info.ModTime().Equal(last) {
		_ = h.load()
	}
}

func (h *HashList) Scan(_ context.Context, in ScanInput) (ScanResult, error) {
	h.refresh()
	h.mu.Lock()
	sha, phash := h.sha, h.phash
	h.mu.Unlock()
	for _, data := range [][]byte{in.Original, in.Full} {
		if len(data) == 0 {
			continue
		}
		sum := sha256.Sum256(data)
		if label, ok := sha[hex.EncodeToString(sum[:])]; ok {
			return ScanResult{Verdict: Match, Scanner: h.Name(), Signals: map[string]string{"kind": "sha256", "strength": "exact", "label": label}}, nil
		}
	}
	if len(phash) == 0 || len(in.Full) == 0 {
		return ScanResult{Verdict: Clean, Scanner: h.Name()}, nil
	}
	hash, err := PerceptualHash(in.Full)
	if err != nil {
		return ScanResult{}, err
	}
	best, label := 65, ""
	for _, e := range phash {
		if d := bits.OnesCount64(hash ^ e.hash); d < best {
			best, label = d, e.label
		}
	}
	signals := map[string]string{"kind": "phash", "strength": "perceptual", "distance": strconv.Itoa(best), "label": label}
	if best <= h.FlagDistance {
		// Never a Match, however close: see the Match constant.
		return ScanResult{Verdict: Flagged, Scanner: h.Name(), Signals: signals}, nil
	}
	return ScanResult{Verdict: Clean, Scanner: h.Name()}, nil
}

// PerceptualHash is a 64-bit difference hash: the picture is shrunk to 9x8 grey pixels and each bit says
// whether a pixel is brighter than its right neighbour. It survives re-encoding, resizing and small
// edits, which a cryptographic digest does not. It is not PhotoDNA and is not a substitute for it.
func PerceptualHash(data []byte) (uint64, error) {
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return 0, ErrUnsupported
	}
	small := imaging.Grayscale(imaging.Resize(img, 9, 8, imaging.Box))
	var hash uint64
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			l, _, _, _ := small.At(x, y).RGBA()
			r, _, _, _ := small.At(x+1, y).RGBA()
			hash <<= 1
			if l > r {
				hash |= 1
			}
		}
	}
	return hash, nil
}

// ---- HTTP provider

// HTTPProvider is a skeleton adapter for a hosted scanning service (PhotoDNA-style). It POSTs the
// re-encoded JPEG as application/octet-stream to URL with "Authorization: Bearer <key>" and expects JSON
//
//	{"verdict":"clean|flagged|match","reference":"<provider case or match id, optional>"}
//
// Real services have their own request shapes and onboarding (PhotoDNA Cloud Service is by application
// to Microsoft); put the translation in Scan when one is chosen. Redirects are not followed, the body is
// size limited, and any non-200 answer is an error (the photo then stays unseen: fail closed).
type HTTPProvider struct {
	URL    string
	Key    string
	Client *http.Client
}

// NewHTTPProvider reads the bearer key from keyFile. In production the URL must be https.
func NewHTTPProvider(rawURL, keyFile string, production bool) (*HTTPProvider, error) {
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && (production || u.Scheme != "http")) {
		return nil, errors.New("SCAN_PROVIDER_URL must be an https URL")
	}
	key, err := os.ReadFile(keyFile)
	if err != nil || strings.TrimSpace(string(key)) == "" {
		return nil, errors.New("SCAN_PROVIDER_KEY_FILE cannot be read")
	}
	return &HTTPProvider{URL: rawURL, Key: strings.TrimSpace(string(key)), Client: &http.Client{
		Timeout:       10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (p *HTTPProvider) Name() string { return "provider" }

// scanUpstreamErrors counts provider calls that failed (unreachable, a non-200 answer or an answer that is not understood):
// while they fail, uploads are not being screened. The alert rule HiyallScanUpstreamErrors reads it.
var scanUpstreamErrors = metrics.NewCounter("hiyall_scan_upstream_errors_total", "Upload scan provider calls that failed, by scanner.", "scanner")

func init() { scanUpstreamErrors.Preset("provider") }

func (p *HTTPProvider) Scan(ctx context.Context, in ScanInput) (ScanResult, error) {
	r, err := p.scan(ctx, in)
	if err != nil {
		scanUpstreamErrors.Inc(p.Name())
	}
	return r, err
}

func (p *HTTPProvider) scan(ctx context.Context, in ScanInput) (ScanResult, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.URL, bytes.NewReader(in.Full))
	if err != nil {
		return ScanResult{}, err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "Bearer "+p.Key)
	resp, err := p.Client.Do(req)
	if err != nil {
		return ScanResult{}, errors.New("scan provider unreachable")
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode != http.StatusOK {
		return ScanResult{}, fmt.Errorf("scan provider answered %d", resp.StatusCode)
	}
	var out struct {
		Verdict   string `json:"verdict"`
		Reference string `json:"reference"`
	}
	if json.Unmarshal(body, &out) != nil {
		return ScanResult{}, errors.New("scan provider answer not understood")
	}
	r := ScanResult{Scanner: p.Name(), Signals: map[string]string{}}
	if out.Reference != "" && len(out.Reference) <= 200 {
		r.Signals["reference"] = out.Reference
	}
	switch Verdict(out.Verdict) {
	case Clean, Flagged, Match:
		r.Verdict = Verdict(out.Verdict)
	default:
		return ScanResult{}, errors.New("scan provider answer not understood")
	}
	return r, nil
}

// Hold prefix of quarantined objects. Nothing under it is ever signed for members.
const HoldPrefix = "hold/"

// HoldKeys are the keys a quarantined upload is kept under.
func HoldKeys(mediaID string) (original, full string) {
	return HoldPrefix + mediaID + "/original", HoldPrefix + mediaID + "/full.jpg"
}

// SHA256Hex is the digest recorded as evidence of the exact uploaded bytes.
func SHA256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
