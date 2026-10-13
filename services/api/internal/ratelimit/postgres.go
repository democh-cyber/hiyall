package ratelimit

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/time/rate"
)

// DB is the part of *pgxpool.Pool the Postgres limiter uses.
type DB interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
}

// Postgres is a token bucket shared by every API node, stored in the rate_limits table
// (database/migrations/0030_rate_limits.sql). One request is one statement: it refills the bucket from
// the database clock, takes a token if there is one and returns the outcome, atomically, because
// INSERT ... ON CONFLICT DO UPDATE locks the row for the duration of the update.
//
// It costs one indexed write per limited request. Failing to reach the database is returned as an
// error; the caller decides whether to fail open (the API does, and counts it).
type Postgres struct {
	db    DB
	name  string
	limit rate.Limit
	burst int
}

// NewPostgres returns a shared limiter. name separates this limiter's buckets from the others'.
func NewPostgres(db DB, name string, limit rate.Limit, burst int) *Postgres {
	return &Postgres{db: db, name: name, limit: limit, burst: burst}
}

// refilled is the bucket's token count after refilling to the statement clock; it is spelled out once
// and used three times so that the outcome, the new count and the "full at" time agree.
const refilled = `LEAST($2::float8, r.tokens + GREATEST(0, EXTRACT(EPOCH FROM ((SELECT t FROM c) - r.updated_at))) * $3::float8)`

// A bucket that does not exist yet starts full. The new updated_at never moves backwards: if the
// statement waited on the row lock, its clock reading is older than the previous writer's.
const allowSQL = `
WITH c AS (SELECT clock_timestamp() AS t)
INSERT INTO rate_limits AS r (bucket, tokens, updated_at, full_at, allowed)
SELECT $1::text, $2::float8 - 1, c.t, c.t + make_interval(secs => 1 / $3::float8), true FROM c
ON CONFLICT (bucket) DO UPDATE SET
  allowed = ` + refilled + ` >= 1,
  tokens = CASE WHEN ` + refilled + ` >= 1 THEN ` + refilled + ` - 1 ELSE ` + refilled + ` END,
  updated_at = GREATEST(r.updated_at, (SELECT t FROM c)),
  full_at = GREATEST(r.updated_at, (SELECT t FROM c)) + make_interval(secs => GREATEST(0, $2::float8 - (CASE WHEN ` + refilled + ` >= 1 THEN ` + refilled + ` - 1 ELSE ` + refilled + ` END)) / $3::float8)
RETURNING allowed, tokens`

// Allow implements Limiter.
func (p *Postgres) Allow(ctx context.Context, key string) (Decision, error) {
	var allowed bool
	var tokens float64
	if err := p.db.QueryRow(ctx, allowSQL, p.bucket(key), float64(p.burst), float64(p.limit)).Scan(&allowed, &tokens); err != nil {
		return Decision{}, err
	}
	if allowed {
		return Decision{Allowed: true}, nil
	}
	wait := (1 - tokens) / float64(p.limit)
	return Decision{RetryAfter: time.Duration(math.Ceil(wait*1000)) * time.Millisecond}, nil
}

// Reset implements Limiter.
func (p *Postgres) Reset(ctx context.Context, key string) error {
	_, err := p.db.Exec(ctx, `DELETE FROM rate_limits WHERE bucket = $1`, p.bucket(key))
	return err
}

// bucket is "<limiter>:<key>". Keys are account ids today; a key too long for the column is hashed.
func (p *Postgres) bucket(key string) string {
	if len(p.name)+1+len(key) > 200 {
		sum := sha256.Sum256([]byte(key))
		key = hex.EncodeToString(sum[:])
	}
	return p.name + ":" + key
}

// Purge deletes up to batch buckets that have been full for more than a minute: they carry no
// information, since a new bucket starts full. It returns the number deleted, for the maintenance job.
func Purge(ctx context.Context, db DB, batch int) (int64, error) {
	if batch <= 0 {
		return 0, errors.New("ratelimit: batch must be positive")
	}
	tag, err := db.Exec(ctx, `DELETE FROM rate_limits WHERE bucket IN (SELECT bucket FROM rate_limits WHERE full_at < clock_timestamp() - interval '1 minute' LIMIT $1)`, batch)
	return tag.RowsAffected(), err
}
