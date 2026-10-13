// Package metrics is a small, dependency-free Prometheus text-format registry.
//
// Other packages register their own series on Default and import nothing else:
//
//	var pushSent = metrics.NewCounter("hiyall_push_sent_total", "Push wake-ups sent.", "provider", "result")
//	...
//	pushSent.Inc("fcm", "ok")
//
// Registration is get-or-create by name, so tests that build many servers do not panic; registering
// the same name with a different type or label set does panic, because that is a programming error.
//
// Cardinality: every labelled series is bounded (MaxSeries per metric). A new label combination past
// the bound is folded into one series whose labels are all "overflow" and counted in
// hiyall_metrics_overflow_total, so a bug (or an attacker) minting label values cannot grow memory
// or the scrape without limit. Never use an id, token, user input or raw URL path as a label value.
package metrics

import (
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// MaxSeries is the most label combinations one metric keeps before folding into "overflow".
const MaxSeries = 500

// ContentType is the Prometheus text exposition media type.
const ContentType = "text/plain; version=0.0.4; charset=utf-8"

type kind int

const (
	kindCounter kind = iota
	kindGauge
	kindHistogram
)

func (k kind) String() string {
	return [...]string{"counter", "gauge", "histogram"}[k]
}

// Registry holds metrics and writes them in exposition format.
type Registry struct {
	mu      sync.RWMutex
	byName  map[string]*family
	overrun *family
}

// NewRegistry returns an empty registry that already carries its own overflow counter.
func NewRegistry() *Registry {
	r := &Registry{byName: map[string]*family{}}
	r.overrun = r.family("hiyall_metrics_overflow_total", "Label combinations folded into the overflow series because a metric reached its series limit.", kindCounter, []string{"metric"}, nil, nil)
	return r
}

// Default is the process-wide registry served by the metrics listener.
var Default = NewRegistry()

type family struct {
	reg     *Registry
	name    string
	help    string
	kind    kind
	labels  []string
	buckets []float64 // histograms: upper bounds, ascending, without +Inf
	mu      sync.Mutex
	series  map[string]*series
	// fn, when set, computes a single unlabelled value at scrape time.
	fn func() float64
	// collect, when set, yields labelled samples at scrape time (a gauge or counter read from elsewhere).
	collect func(emit func(value float64, labelValues ...string))
}

type series struct {
	labelValues []string
	value       atomic.Uint64 // float64 bits, counters and gauges
	// histogram state, guarded by hmu
	hmu    sync.Mutex
	counts []uint64
	sum    float64
	total  uint64
}

func (r *Registry) family(name, help string, k kind, labels []string, buckets []float64, fn func() float64) *family {
	r.mu.Lock()
	defer r.mu.Unlock()
	if f, ok := r.byName[name]; ok {
		if f.kind != k || strings.Join(f.labels, ",") != strings.Join(labels, ",") {
			panic("metrics: " + name + " registered again with a different type or labels")
		}
		return f
	}
	if !validName(name) {
		panic("metrics: invalid metric name " + strconv.Quote(name))
	}
	for _, l := range labels {
		if !validName(l) || strings.HasPrefix(l, "__") || l == "le" {
			panic("metrics: invalid label name " + strconv.Quote(l))
		}
	}
	f := &family{reg: r, name: name, help: help, kind: k, labels: append([]string(nil), labels...), buckets: buckets, series: map[string]*series{}, fn: fn}
	r.byName[name] = f
	return f
}

func validName(s string) bool {
	if s == "" {
		return false
	}
	for i, c := range s {
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i > 0 && c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

// get returns the series for the label values, folding into overflow past MaxSeries.
func (f *family) get(labelValues []string) *series {
	if len(labelValues) != len(f.labels) {
		panic(fmt.Sprintf("metrics: %s takes %d label values, got %d", f.name, len(f.labels), len(labelValues)))
	}
	key := strings.Join(labelValues, "\xff")
	f.mu.Lock()
	defer f.mu.Unlock()
	if s, ok := f.series[key]; ok {
		return s
	}
	if len(f.series) >= MaxSeries {
		over := make([]string, len(f.labels))
		for i := range over {
			over[i] = "overflow"
		}
		okey := strings.Join(over, "\xff")
		if s, ok := f.series[okey]; ok {
			f.reg.overflow(f.name)
			return s
		}
		labelValues, key = over, okey
		f.reg.overflow(f.name)
	}
	s := &series{labelValues: append([]string(nil), labelValues...)}
	if f.kind == kindHistogram {
		s.counts = make([]uint64, len(f.buckets))
	}
	f.series[key] = s
	return s
}

func (r *Registry) overflow(metric string) {
	if r.overrun == nil || metric == r.overrun.name {
		return
	}
	// The overflow counter is bounded by the number of metrics, which are all declared in code.
	r.overrun.get([]string{metric}).add(1)
}

func (s *series) add(v float64) {
	for {
		old := s.value.Load()
		if s.value.CompareAndSwap(old, math.Float64bits(math.Float64frombits(old)+v)) {
			return
		}
	}
}
func (s *series) set(v float64) { s.value.Store(math.Float64bits(v)) }
func (s *series) get() float64  { return math.Float64frombits(s.value.Load()) }
func (s *series) observe(f *family, v float64) {
	s.hmu.Lock()
	defer s.hmu.Unlock()
	for i, b := range f.buckets {
		if v <= b {
			s.counts[i]++
			break
		}
	}
	s.sum += v
	s.total++
}

// Counter only goes up. Create it with NewCounter; label values are passed to Inc and Add.
type Counter struct{ f *family }

// NewCounter registers (or returns) a counter on Default.
func NewCounter(name, help string, labels ...string) *Counter {
	return Default.NewCounter(name, help, labels...)
}

// NewCounter registers (or returns) a counter.
func (r *Registry) NewCounter(name, help string, labels ...string) *Counter {
	return &Counter{r.family(name, help, kindCounter, labels, nil, nil)}
}

// Inc adds one.
func (c *Counter) Inc(labelValues ...string) { c.f.get(labelValues).add(1) }

// Add adds v, which must not be negative.
func (c *Counter) Add(v float64, labelValues ...string) {
	if v < 0 {
		return
	}
	c.f.get(labelValues).add(v)
}

// Gauge goes up and down.
type Gauge struct{ f *family }

// NewGauge registers (or returns) a gauge on Default.
func NewGauge(name, help string, labels ...string) *Gauge {
	return Default.NewGauge(name, help, labels...)
}

// NewGauge registers (or returns) a gauge.
func (r *Registry) NewGauge(name, help string, labels ...string) *Gauge {
	return &Gauge{r.family(name, help, kindGauge, labels, nil, nil)}
}
func (g *Gauge) Set(v float64, labelValues ...string) { g.f.get(labelValues).set(v) }
func (g *Gauge) Add(v float64, labelValues ...string) { g.f.get(labelValues).add(v) }
func (g *Gauge) Inc(labelValues ...string)            { g.f.get(labelValues).add(1) }
func (g *Gauge) Dec(labelValues ...string)            { g.f.get(labelValues).add(-1) }

// NewGaugeFunc registers a gauge read at scrape time (pool sizes, queue lengths, connection counts).
// Registering the same name again replaces the function, so the newest server instance wins in tests.
func NewGaugeFunc(name, help string, fn func() float64) { Default.NewGaugeFunc(name, help, fn) }

func (r *Registry) NewGaugeFunc(name, help string, fn func() float64) {
	f := r.family(name, help, kindGauge, nil, nil, fn)
	f.mu.Lock()
	f.fn = fn
	f.mu.Unlock()
}

// NewCounterFunc is NewGaugeFunc for a monotonically increasing value kept elsewhere.
func NewCounterFunc(name, help string, fn func() float64) { Default.NewCounterFunc(name, help, fn) }

func (r *Registry) NewCounterFunc(name, help string, fn func() float64) {
	f := r.family(name, help, kindCounter, nil, nil, fn)
	f.mu.Lock()
	f.fn = fn
	f.mu.Unlock()
}

// NewGaugeCollector registers a labelled gauge computed at scrape time: collect calls emit once per
// series. The labels are the caller's responsibility to keep small; the series limit still applies at scrape.
func NewGaugeCollector(name, help string, labels []string, collect func(emit func(value float64, labelValues ...string))) {
	Default.NewGaugeCollector(name, help, labels, collect)
}

func (r *Registry) NewGaugeCollector(name, help string, labels []string, collect func(emit func(value float64, labelValues ...string))) {
	f := r.family(name, help, kindGauge, labels, nil, nil)
	f.mu.Lock()
	f.collect = collect
	f.mu.Unlock()
}

// DefBuckets suit request latencies in seconds.
var DefBuckets = []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10}

// Histogram counts observations into cumulative buckets.
type Histogram struct{ f *family }

// NewHistogram registers (or returns) a histogram on Default. nil buckets means DefBuckets.
func NewHistogram(name, help string, buckets []float64, labels ...string) *Histogram {
	return Default.NewHistogram(name, help, buckets, labels...)
}

func (r *Registry) NewHistogram(name, help string, buckets []float64, labels ...string) *Histogram {
	if buckets == nil {
		buckets = DefBuckets
	}
	b := append([]float64(nil), buckets...)
	sort.Float64s(b)
	return &Histogram{r.family(name, help, kindHistogram, labels, b, nil)}
}

// Observe records one value.
func (h *Histogram) Observe(v float64, labelValues ...string) { h.f.get(labelValues).observe(h.f, v) }

// WriteTo writes every metric in the Prometheus text format, sorted by name then label values, so the
// output is stable and diffable.
func (r *Registry) WriteTo(w io.Writer) (int64, error) {
	r.mu.RLock()
	families := make([]*family, 0, len(r.byName))
	for _, f := range r.byName {
		families = append(families, f)
	}
	r.mu.RUnlock()
	sort.Slice(families, func(i, j int) bool { return families[i].name < families[j].name })
	var sb strings.Builder
	for _, f := range families {
		f.write(&sb)
	}
	n, err := io.WriteString(w, sb.String())
	return int64(n), err
}

type sample struct {
	labelValues []string
	value       float64
	hist        *series
}

func (f *family) write(sb *strings.Builder) {
	f.mu.Lock()
	fn, collect := f.fn, f.collect
	f.mu.Unlock()
	var samples []sample
	switch {
	case fn != nil:
		samples = []sample{{value: fn()}}
	case collect != nil:
		collect(func(v float64, lv ...string) {
			if len(lv) == len(f.labels) && len(samples) < MaxSeries {
				samples = append(samples, sample{labelValues: lv, value: v})
			}
		})
	default:
		f.mu.Lock()
		for _, s := range f.series {
			samples = append(samples, sample{labelValues: s.labelValues, value: s.get(), hist: s})
		}
		f.mu.Unlock()
	}
	if len(samples) == 0 {
		return
	}
	sort.Slice(samples, func(i, j int) bool {
		return strings.Join(samples[i].labelValues, "\xff") < strings.Join(samples[j].labelValues, "\xff")
	})
	sb.WriteString("# HELP " + f.name + " " + escapeHelp(f.help) + "\n# TYPE " + f.name + " " + f.kind.String() + "\n")
	for _, s := range samples {
		if f.kind != kindHistogram {
			sb.WriteString(f.name + labelString(f.labels, s.labelValues, "", "") + " " + formatFloat(s.value) + "\n")
			continue
		}
		h := s.hist
		h.hmu.Lock()
		counts, sum, total := append([]uint64(nil), h.counts...), h.sum, h.total
		h.hmu.Unlock()
		var cumulative uint64
		for i, b := range f.buckets {
			cumulative += counts[i]
			sb.WriteString(f.name + "_bucket" + labelString(f.labels, s.labelValues, "le", formatFloat(b)) + " " + strconv.FormatUint(cumulative, 10) + "\n")
		}
		sb.WriteString(f.name + "_bucket" + labelString(f.labels, s.labelValues, "le", "+Inf") + " " + strconv.FormatUint(total, 10) + "\n")
		sb.WriteString(f.name + "_sum" + labelString(f.labels, s.labelValues, "", "") + " " + formatFloat(sum) + "\n")
		sb.WriteString(f.name + "_count" + labelString(f.labels, s.labelValues, "", "") + " " + strconv.FormatUint(total, 10) + "\n")
	}
}

func labelString(names, values []string, extraName, extraValue string) string {
	if len(names) == 0 && extraName == "" {
		return ""
	}
	parts := make([]string, 0, len(names)+1)
	for i, n := range names {
		parts = append(parts, n+`="`+escapeValue(values[i])+`"`)
	}
	if extraName != "" {
		parts = append(parts, extraName+`="`+escapeValue(extraValue)+`"`)
	}
	return "{" + strings.Join(parts, ",") + "}"
}

func escapeValue(s string) string {
	return strings.NewReplacer(`\`, `\\`, "\n", `\n`, `"`, `\"`).Replace(s)
}
func escapeHelp(s string) string { return strings.NewReplacer(`\`, `\\`, "\n", `\n`).Replace(s) }

func formatFloat(v float64) string {
	switch {
	case math.IsInf(v, 1):
		return "+Inf"
	case math.IsInf(v, -1):
		return "-Inf"
	case math.IsNaN(v):
		return "NaN"
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}
