// Package errreport sends handler panics and unexpected 500s to Sentry (or any Sentry-compatible
// endpoint) through its envelope API.
//
// It is a small HTTP client instead of the sentry-go SDK on purpose. The SDK's defaults attach the
// request (URL, headers, cookies), environment variables and the host name, and every one of those has
// to be switched off and audited again on each upgrade. This API serves end-to-end encrypted chat
// metadata, birth dates, positions and presigned media URLs, so the safer design is a client that can
// only ever send what it is handed: a route pattern, a request id, a scrubbed message and a stack.
// It adds no dependency to go.mod.
package errreport

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"hiyall/services/api/internal/httpapi"
)

// DSN is a parsed Sentry DSN: https://<key>@<host>/<project>.
type DSN struct {
	Key, Endpoint string
}

// ParseDSN checks and splits a DSN. The error never contains it, because it holds the project key.
func ParseDSN(raw string) (DSN, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	bad := errors.New("errreport: invalid DSN")
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User == nil || u.User.Username() == "" {
		return DSN{}, bad
	}
	path := strings.Trim(u.Path, "/")
	project := path[strings.LastIndex(path, "/")+1:]
	prefix := strings.TrimSuffix(path, project)
	if _, err := strconv.Atoi(project); err != nil {
		return DSN{}, bad
	}
	return DSN{Key: u.User.Username(), Endpoint: fmt.Sprintf("%s://%s/%sapi/%s/envelope/", u.Scheme, u.Host, prefix, project)}, nil
}

// Options configure a Reporter. Zero values are fine apart from DSN.
type Options struct {
	DSN         string
	Environment string
	Release     string
	// HTTPClient defaults to one with a 5 second timeout. Tests replace it.
	HTTPClient *http.Client
	// Queue is how many reports may wait; further ones are dropped, never blocking a request. Default 64.
	Queue int
}

// Reporter implements httpapi.ErrorReporter.
type Reporter struct {
	dsn         DSN
	environment string
	release     string
	client      *http.Client
	queue       chan []byte
	wg          sync.WaitGroup
	closeOnce   sync.Once
	dropped     int64
	mu          sync.Mutex
}

var _ httpapi.ErrorReporter = (*Reporter)(nil)

// New starts the sender goroutine. Call Flush at shutdown.
func New(o Options) (*Reporter, error) {
	dsn, err := ParseDSN(o.DSN)
	if err != nil {
		return nil, err
	}
	r := &Reporter{dsn: dsn, environment: o.Environment, release: o.Release, client: o.HTTPClient}
	if r.client == nil {
		r.client = &http.Client{Timeout: 5 * time.Second}
	}
	n := o.Queue
	if n <= 0 {
		n = 64
	}
	r.queue = make(chan []byte, n)
	r.wg.Add(1)
	go r.run()
	return r, nil
}

// Report queues one failure. It never blocks and never panics.
func (r *Reporter) Report(_ context.Context, rep httpapi.ErrorReport) {
	body, err := r.envelope(rep, time.Now())
	if err != nil {
		return
	}
	select {
	case r.queue <- body:
	default:
		r.mu.Lock()
		r.dropped++
		r.mu.Unlock()
	}
}

// Dropped is how many reports were discarded because the queue was full.
func (r *Reporter) Dropped() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.dropped
}

// Flush stops accepting reports and waits for queued ones, until ctx ends.
func (r *Reporter) Flush(ctx context.Context) {
	r.closeOnce.Do(func() { close(r.queue) })
	done := make(chan struct{})
	go func() { r.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

func (r *Reporter) run() {
	defer r.wg.Done()
	for body := range r.queue {
		req, err := http.NewRequest(http.MethodPost, r.dsn.Endpoint, bytes.NewReader(body))
		if err != nil {
			continue
		}
		req.Header.Set("Content-Type", "application/x-sentry-envelope")
		req.Header.Set("X-Sentry-Auth", "Sentry sentry_version=7, sentry_client=hiyall-api/1, sentry_key="+r.dsn.Key)
		resp, err := r.client.Do(req)
		if err != nil {
			// The error text can quote the endpoint, which holds the project id; log the kind only.
			slog.Warn("error report not sent", "reason", "transport")
			continue
		}
		resp.Body.Close()
		if resp.StatusCode >= 300 {
			slog.Warn("error report refused", "status", resp.StatusCode)
		}
	}
}

type frame struct {
	Function string `json:"function,omitempty"`
	Filename string `json:"filename"`
	Lineno   int    `json:"lineno,omitempty"`
}

type event struct {
	EventID     string            `json:"event_id"`
	Timestamp   string            `json:"timestamp"`
	Platform    string            `json:"platform"`
	Level       string            `json:"level"`
	Environment string            `json:"environment,omitempty"`
	Release     string            `json:"release,omitempty"`
	ServerName  string            `json:"server_name"`
	Tags        map[string]string `json:"tags,omitempty"`
	Exception   struct {
		Values []exception `json:"values"`
	} `json:"exception"`
}

type exception struct {
	Type       string `json:"type"`
	Value      string `json:"value"`
	Stacktrace *struct {
		Frames []frame `json:"frames"`
	} `json:"stacktrace,omitempty"`
}

// envelope builds the request body for one report. Nothing but the fields of event can leave.
func (r *Reporter) envelope(rep httpapi.ErrorReport, now time.Time) ([]byte, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return nil, err
	}
	ev := event{
		EventID:     hex.EncodeToString(id[:]),
		Timestamp:   now.UTC().Format(time.RFC3339),
		Platform:    "go",
		Level:       "error",
		Environment: r.environment,
		Release:     r.release,
		ServerName:  "", // the host name says nothing useful and is dropped
		Tags:        map[string]string{"request_id": clip(rep.RequestID, 64), "route": clip(rep.Route, 120), "method": clip(rep.Method, 10)},
	}
	x := exception{Type: "error", Value: "unexpected failure"}
	switch {
	case rep.Panic != nil:
		ev.Level = "fatal"
		x.Type = "panic"
		x.Value = Scrub(fmt.Sprint(rep.Panic))
	case rep.Err != nil:
		x.Type = fmt.Sprintf("%T", rep.Err)
		x.Value = Scrub(rep.Err.Error())
	}
	if len(rep.Stack) > 0 {
		x.Stacktrace = &struct {
			Frames []frame `json:"frames"`
		}{Frames: ParseStack(rep.Stack)}
	}
	ev.Exception.Values = []exception{x}
	payload, err := json.Marshal(ev)
	if err != nil {
		return nil, err
	}
	head, _ := json.Marshal(map[string]string{"event_id": ev.EventID, "sent_at": ev.Timestamp})
	item, _ := json.Marshal(map[string]any{"type": "event", "length": len(payload)})
	var b bytes.Buffer
	b.Write(head)
	b.WriteByte('\n')
	b.Write(item)
	b.WriteByte('\n')
	b.Write(payload)
	b.WriteByte('\n')
	return b.Bytes(), nil
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

var (
	urlText     = regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+`)
	bearer      = regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._~+/=-]+`)
	jwt         = regexp.MustCompile(`eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`)
	email       = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`)
	uuid        = regexp.MustCompile(`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`)
	pgDetail    = regexp.MustCompile(`\(([^()]*)\)=\(([^()]*)\)`)
	secretParam = regexp.MustCompile(`(?i)\b(password|passwd|secret|token|key|signature|sig|authorization|x-amz-[a-z-]+)=[^\s&"']+`)
)

// Scrub removes what must not reach an error tracker from free text: URLs (presigned URLs carry their
// signature in the query), bearer and JWT tokens, emails, ids, Postgres "(column)=(value)" details and
// key=value secrets. The result is cut to 300 characters.
func Scrub(s string) string {
	s = urlText.ReplaceAllString(s, "[url]")
	s = bearer.ReplaceAllString(s, "Bearer [redacted]")
	s = jwt.ReplaceAllString(s, "[token]")
	s = email.ReplaceAllString(s, "[email]")
	s = pgDetail.ReplaceAllString(s, "($1)=([value])")
	s = secretParam.ReplaceAllString(s, "$1=[redacted]")
	s = uuid.ReplaceAllString(s, ":id")
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return s
}

// ParseStack turns the text of runtime/debug.Stack into frames, oldest call first as Sentry expects,
// skipping the goroutine header. Only function names and source positions are kept; argument values
// (which can hold data) are dropped.
func ParseStack(stack []byte) []frame {
	lines := strings.Split(string(stack), "\n")
	var frames []frame
	for i := 0; i+1 < len(lines); i++ {
		fn := strings.TrimSpace(lines[i])
		loc := lines[i+1]
		if !strings.HasPrefix(loc, "\t") || fn == "" || strings.HasPrefix(fn, "goroutine ") {
			continue
		}
		loc = strings.TrimSpace(loc)
		if j := strings.LastIndex(loc, " +0x"); j >= 0 {
			loc = loc[:j]
		}
		colon := strings.LastIndex(loc, ":")
		if colon < 0 {
			continue
		}
		n, _ := strconv.Atoi(loc[colon+1:])
		if p := strings.Index(fn, "("); p >= 0 {
			fn = fn[:p]
		}
		frames = append(frames, frame{Function: fn, Filename: loc[:colon], Lineno: n})
		i++
		if len(frames) >= 50 {
			break
		}
	}
	for l, h := 0, len(frames)-1; l < h; l, h = l+1, h-1 {
		frames[l], frames[h] = frames[h], frames[l]
	}
	return frames
}
