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
// job). It does not decide what a read or delete means: the caller refuses, or accepts the risk when a bucket
// lock is in place. Each run leaves at most one tiny object under CanaryPrefix.
func EvidenceCanary(ctx context.Context, s Store) (CanaryResult, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return CanaryResult{}, err
	}
	res := CanaryResult{Key: CanaryPrefix + time.Now().UTC().Format("20060102T150405Z") + "-" + hex.EncodeToString(b[:])}
	body := []byte("hiyall evidence token canary: safe to delete")
	if err := s.Put(ctx, res.Key, body, "text/plain"); err != nil {
		return CanaryResult{}, errors.New("the evidence token cannot write a probe object (code " + ErrorCode(err) + ")")
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
