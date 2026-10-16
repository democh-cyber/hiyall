package media

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// guarded is a store whose permissions are chosen by the test.
type guarded struct {
	*Memory
	denyPut, denyGet, denyDelete bool
}

var errDenied = errors.New("AccessDenied")

func (g guarded) Put(ctx context.Context, k string, d []byte, ct string) error {
	if g.denyPut {
		return errDenied
	}
	return g.Memory.Put(ctx, k, d, ct)
}
func (g guarded) Get(ctx context.Context, k string, l int64) ([]byte, error) {
	if g.denyGet {
		return nil, errDenied
	}
	return g.Memory.Get(ctx, k, l)
}
func (g guarded) Delete(ctx context.Context, k ...string) error {
	if g.denyDelete {
		return errDenied
	}
	return g.Memory.Delete(ctx, k...)
}

func TestEvidenceCanaryReportsWhatTheCredentialCanDo(t *testing.T) {
	ctx := context.Background()
	for name, tc := range map[string]struct {
		g                  guarded
		wantRead, wantDel  bool
		wantWriteOnly, err bool
	}{
		"write only":   {g: guarded{Memory: NewMemory(), denyGet: true, denyDelete: true}, wantWriteOnly: true},
		"can read":     {g: guarded{Memory: NewMemory(), denyDelete: true}, wantRead: true},
		"can delete":   {g: guarded{Memory: NewMemory(), denyGet: true}, wantDel: true},
		"full access":  {g: guarded{Memory: NewMemory()}, wantRead: true, wantDel: true},
		"cannot write": {g: guarded{Memory: NewMemory(), denyPut: true}, err: true},
	} {
		t.Run(name, func(t *testing.T) {
			res, err := EvidenceCanary(ctx, tc.g)
			if (err != nil) != tc.err {
				t.Fatalf("err %v", err)
			}
			if tc.err {
				return
			}
			if res.CanRead != tc.wantRead || res.CanDelete != tc.wantDel || res.WriteOnly() != tc.wantWriteOnly {
				t.Fatalf("%+v", res)
			}
			if !strings.HasPrefix(res.Key, CanaryPrefix) || strings.HasPrefix(res.Key, HoldPrefix) {
				t.Fatalf("probe key %q", res.Key)
			}
			if tc.g.Has(res.Key) == tc.wantDel {
				t.Fatalf("object presence after the probe: %v", tc.g.Has(res.Key))
			}
		})
	}
}

func TestMemoryListsByPrefixWithTimes(t *testing.T) {
	m := NewMemory()
	ctx := context.Background()
	_ = m.Put(ctx, "hold/a/original", []byte("x"), "")
	_ = m.Put(ctx, "hold/b/original", []byte("x"), "")
	_ = m.Put(ctx, "canary/z", []byte("x"), "")
	m.Modified["hold/a/original"] = time.Now().Add(-2 * time.Hour)
	got, err := m.List(ctx, "hold/", 10)
	if err != nil || len(got) != 2 || got[0].Key != "hold/a/original" || time.Since(got[0].LastModified) < time.Hour {
		t.Fatalf("%+v %v", got, err)
	}
	if got, _ = m.List(ctx, "hold/", 1); len(got) != 1 {
		t.Fatalf("limit: %+v", got)
	}
}
