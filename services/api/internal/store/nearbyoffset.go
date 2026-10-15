package store

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"hiyall/services/api/internal/domain"
)

// The Nearby offset key (NEARBY_OFFSET_KEY) is process-wide: every Store in the process moves every member by
// the same member-specific vector. Production sets it at start (cmd/api); without one (development and tests)
// a random key is made on first use, so offsets are stable for the life of the process.
var (
	nearbyKeyMu sync.Mutex
	nearbyKey   []byte
)

// SetNearbyOffsetKey installs the offset key. A nil or empty key leaves the current one.
func SetNearbyOffsetKey(key []byte) {
	if len(key) == 0 {
		return
	}
	nearbyKeyMu.Lock()
	nearbyKey = append([]byte(nil), key...)
	nearbyKeyMu.Unlock()
}

func nearbyOffsetKey() []byte {
	nearbyKeyMu.Lock()
	defer nearbyKeyMu.Unlock()
	if nearbyKey == nil {
		nearbyKey = make([]byte, 32)
		if _, err := rand.Read(nearbyKey); err != nil {
			panic(err)
		}
	}
	return nearbyKey
}

// memberOffset is the displacement applied to a member's shared point: the explicit pin when one is set
// (nearby_prefs.offset_day not null; production never writes one, tests use it to store exact points), else
// the stable offset derived from the key. The radius is the member's band's (2 km, 5 km for minors).
func memberOffset(userID string, pinned bool, north, east float64, minor bool) domain.Offset {
	if pinned {
		return domain.Offset{NorthKm: north, EastKm: east}
	}
	radius := domain.NearbyOffsetKm
	if minor {
		radius = domain.MinorNearbyOffsetKm
	}
	return domain.StableOffset(nearbyOffsetKey(), userID, radius)
}

// nearbyProbeHash keys a probe subject (an account or an address) and a centre so the table holds neither.
func nearbyProbeHash(kind, value string) []byte {
	mac := hmac.New(sha256.New, nearbyOffsetKey())
	mac.Write([]byte("nearby-probe\x00" + kind + "\x00" + value))
	return mac.Sum(nil)[:16]
}

// CountNearbyProbe records that the account, searching from source address addr, used the stored point
// centre (any stable text for it, such as a keyed tag) as the centre of a Nearby search today, and refuses
// with 429 DAILY_LIMIT when that would be one centre too many for the account or for the address. A centre
// already used today is free. addr may be empty (no limit per address).
func (s *Store) CountNearbyProbe(ctx context.Context, user, addr, centre string, perAccount, perAddress int) error {
	subjects := []struct {
		hash  []byte
		limit int
	}{{nearbyProbeHash("account", user), perAccount}}
	if addr != "" {
		subjects = append(subjects, struct {
			hash  []byte
			limit int
		}{nearbyProbeHash("address", addr), perAddress})
	}
	c := nearbyProbeHash("centre", centre)
	return mapped(s.inTx(ctx, func(tx pgx.Tx) error {
		for _, sub := range subjects {
			// One writer per subject at a time, so the count and the insert cannot race past the cap.
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended(encode($1::bytea,'hex'),41))`, sub.hash); err != nil {
				return err
			}
			var known bool
			var n int
			if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM nearby_probe_centres WHERE subject=$1 AND day=(now() AT TIME ZONE 'UTC')::date AND centre=$2),
 (SELECT count(*) FROM nearby_probe_centres WHERE subject=$1 AND day=(now() AT TIME ZONE 'UTC')::date)`, sub.hash, c).Scan(&known, &n); err != nil {
				return err
			}
			if known {
				continue
			}
			if n >= sub.limit {
				return domain.DailyLimitError(domain.DailyNearbyCentres, domain.UntilNextUTCDay(time.Now()))
			}
			if _, err := tx.Exec(ctx, `INSERT INTO nearby_probe_centres(subject,day,centre) VALUES($1,(now() AT TIME ZONE 'UTC')::date,$2) ON CONFLICT DO NOTHING`, sub.hash, c); err != nil {
				return err
			}
		}
		return nil
	}))
}

// PurgeNearbyProbes deletes probe records older than keepDays days, at most batch rows per call.
func (s *Store) PurgeNearbyProbes(ctx context.Context, keepDays, batch int) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM nearby_probe_centres WHERE ctid IN (SELECT ctid FROM nearby_probe_centres WHERE day<(now() AT TIME ZONE 'UTC')::date-$1::int LIMIT $2)`, keepDays, batch)
	return tag.RowsAffected(), err
}
