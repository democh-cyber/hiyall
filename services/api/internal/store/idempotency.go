package store

import (
	"bytes"
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// Idempotency (audit G8). Creating a post, a story or a space entry may carry a client key. The key is claimed
// inside the transaction that creates the item (claimKey), so a retry and a racing duplicate see the first
// result and create nothing; see migration 0038.

// Idem is the optional idempotency of one create: Key is the client's UUID ("" means none) and Hash identifies
// the request body, so the same key with another body is refused.
type Idem struct {
	Key  string
	Hash []byte
}

// ErrIdempotencyReused is 422 IDEMPOTENCY_KEY_REUSED: the key was already used for another request.
var ErrIdempotencyReused = &domain.PolicyError{Status: 422, Code: "IDEMPOTENCY_KEY_REUSED", Message: "That Idempotency-Key was used for a different request"}

// IdempotencyRetention is how long a key is remembered.
const IdempotencyRetention = 24 * time.Hour

// claimKey records key for ref in tx. It reports replay=true and the original ref when the key was already
// claimed by the same request; a concurrent claim waits for the other transaction to finish first.
func claimKey(ctx context.Context, tx pgx.Tx, user string, idem Idem, scope, ref string) (original string, replay bool, err error) {
	if idem.Key == "" {
		return ref, false, nil
	}
	tag, err := tx.Exec(ctx, `INSERT INTO idempotency_keys(user_id,key,scope,request_hash,ref_id) VALUES($1,$2,$3,$4,$5) ON CONFLICT (user_id,key) DO NOTHING`, user, idem.Key, scope, idem.Hash, ref)
	if err != nil {
		return "", false, err
	}
	if tag.RowsAffected() == 1 {
		return ref, false, nil
	}
	var oldScope, oldRef string
	var oldHash []byte
	if err = tx.QueryRow(ctx, `SELECT scope,request_hash,ref_id::text FROM idempotency_keys WHERE user_id=$1 AND key=$2`, user, idem.Key).Scan(&oldScope, &oldHash, &oldRef); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", false, domain.ErrConflict
		}
		return "", false, err
	}
	if oldScope != scope || !bytes.Equal(oldHash, idem.Hash) {
		return "", false, ErrIdempotencyReused
	}
	return oldRef, true, nil
}

// PurgeIdempotencyKeys deletes at most batch keys older than retain.
func (s *Store) PurgeIdempotencyKeys(ctx context.Context, retain time.Duration, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM idempotency_keys WHERE ctid IN (SELECT ctid FROM idempotency_keys WHERE created_at<now()-$1::interval LIMIT $2)`, retain, batch)
	return tag.RowsAffected(), err
}
