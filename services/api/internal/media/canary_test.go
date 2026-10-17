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

// lockedBucket refuses to overwrite or delete an object that exists: what an R2 bucket-lock rule does.
type lockedBucket struct{ *Memory }

func (l lockedBucket) Put(ctx context.Context, k string, d []byte, ct string) error {
	if l.Memory.Has(k) {
		return errDenied
	}
	return l.Memory.Put(ctx, k, d, ct)
}
func (l lockedBucket) Delete(context.Context, ...string) error { return errDenied }

// Round-4 N-6: starts do not pile up probe objects. The probe is named for the day: where the token can delete, nothing is
// left; where a bucket lock keeps it, a second start on the same day finds the key taken and writes one more under a
// unique name at most.
func TestEvidenceCanaryLeavesNothingBehindWhereItCanDeleteAndAtMostOneADayUnderALock(t *testing.T) {
	ctx := context.Background()
	count := func(m *Memory) int {
		objs, err := m.List(ctx, CanaryPrefix, 100)
		if err != nil {
			t.Fatal(err)
		}
		return len(objs)
	}
	open := NewMemory()
	for i := 0; i < 5; i++ {
		res, err := EvidenceCanary(ctx, open)
		if err != nil || !res.CanDelete {
			t.Fatalf("run %d: %+v %v", i, res, err)
		}
	}
	if n := count(open); n != 0 {
		t.Fatalf("a token that can delete left %d probe objects behind after 5 starts", n)
	}
	// Overwrite allowed, delete refused (a retention rule on deletes only): the day's key is reused.
	keeps := guarded{Memory: NewMemory(), denyDelete: true, denyGet: true}
	var key string
	for i := 0; i < 5; i++ {
		res, err := EvidenceCanary(ctx, keeps)
		if err != nil || !res.WriteOnly() {
			t.Fatalf("run %d: %+v %v", i, res, err)
		}
		if key != "" && res.Key != key {
			t.Fatalf("the probe key changed between starts of one day: %s then %s", key, res.Key)
		}
		key = res.Key
	}
	if n := count(keeps.Memory); n != 1 {
		t.Fatalf("five starts on one day left %d probe objects under overwrite-allowed locking, want 1", n)
	}
	if want := CanaryPrefix + time.Now().UTC().Format("20060102"); key != want {
		t.Fatalf("probe key %q, want the day's %q", key, want)
	}
	// A lock that refuses the overwrite too: the second start writes under a unique name, and still tells the truth.
	locked := lockedBucket{Memory: NewMemory()}
	first, err := EvidenceCanary(ctx, locked)
	if err != nil || first.CanDelete {
		t.Fatalf("%+v %v", first, err)
	}
	second, err := EvidenceCanary(ctx, locked)
	if err != nil || second.CanDelete || second.Key == first.Key {
		t.Fatalf("%+v %v", second, err)
	}
}
