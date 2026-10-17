package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"time"
)

// CanaryPrefix is where the evidence-token canary writes. It is outside hold/, so no purge or sweep ever
// treats a probe as evidence.
const CanaryPrefix = "canary/"

// EvidenceBucketMarker is the object the API writes into the evidence bucket at start, holding the bucket's name as the
// API's EVIDENCE_BUCKET has it. The console reads it before it sweeps or purges (admin.Service.EvidenceProbe): "the
// objects are missing" must not be believable from a console that reads some other bucket (round-4 N-7). It sits outside
// hold/ and canary/.
const EvidenceBucketMarker = "evidence-bucket-id"

// CanaryResult is what the API's evidence credential could do to an object it had just written.
type CanaryResult struct {
	// Key is the probe object. When Deleted is false it is still in the bucket (a bucket lock keeps it).
	Key string
	// CanRead: a Get of the probe succeeded.
	CanRead bool
	// CanDelete: a Delete of the probe returned no error.
	CanDelete bool
}

// Writable-only is the property the evidence design wants of the API's token: it can put, it cannot read and it
// cannot delete. Cloudflare R2 tokens cannot be scoped that way, so the property is proved, not assumed.
func (r CanaryResult) WriteOnly() bool { return !r.CanRead && !r.CanDelete }

// EvidenceCanary puts one small probe object with the store's credential and then tries to read and to delete
// it. An error means the probe could not be written at all (the token cannot write evidence, which is its one
// job, or the bucket is down). It does not decide what a read or delete means: the caller refuses, or accepts the
// risk when a bucket lock is in place. The probe is named for the UTC day (canary/20261017), so starts on the same day
// reuse one key and, where the token can delete, nothing is left behind (a bucket lock keeps the one object; if it also
// refuses the overwrite, one more under a unique name is written, which is at most one per start after the first of a
// day).
func EvidenceCanary(ctx context.Context, s Store) (CanaryResult, error) {
	now := time.Now().UTC()
	res := CanaryResult{Key: CanaryPrefix + now.Format("20060102")}
	body := []byte("hiyall evidence token canary: safe to delete")
	err := s.Put(ctx, res.Key, body, "text/plain")
	if err != nil {
		var b [8]byte
		if _, rerr := rand.Read(b[:]); rerr != nil {
			return CanaryResult{}, rerr
		}
		res.Key = CanaryPrefix + now.Format("20060102T150405Z") + "-" + hex.EncodeToString(b[:])
		if err2 := s.Put(ctx, res.Key, body, "text/plain"); err2 != nil {
			return CanaryResult{}, errors.New("the evidence token cannot write a probe object (code " + ErrorCode(err2) + ")")
		}
	}
	if data, err := s.Get(ctx, res.Key, 1<<10); err == nil && len(data) > 0 {
		res.CanRead = true
	}
	if err := s.Delete(ctx, res.Key); err == nil {
		res.CanDelete = true
	}
	return res, nil
}

// ObjectInfo is one listed object.
type ObjectInfo struct {
	Key          string
	LastModified time.Time
}

// Lister lists objects under a prefix. The S3 and in-memory stores implement it; the console uses it, with its
// read-only evidence token, to find hold/ objects that no case row names.
type Lister interface {
	List(ctx context.Context, prefix string, limit int) ([]ObjectInfo, error)
}
