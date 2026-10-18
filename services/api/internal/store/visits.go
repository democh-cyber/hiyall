package store

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// VisitNotice records, for an owner who opted in (notification_prefs.visits, off by default), that visitor opened
// their profile: an Activity item "visited your profile" (event profile.visited, target the visitor) and, through the
// caller, a push. It runs after RecordProfileVisit and never for oneself.
//
//   - At most one notice per visitor and owner per day (an item newer than a day is left alone).
//   - Blocks and the age band apply: a pair that may not see each other gets nothing, which is also what
//     RecordProfileVisit's callers already guarantee.
//   - named says whether a push may carry the visitor's name: only when the visitor's own profile audience lets
//     the owner open their profile. Otherwise the push is the generic "Someone visited your profile". The Activity
//     item itself follows the owner-only visitors list: it names the visitor under the same rules (active account,
//     not barred), which is what that list shows the owner anyway.
func (s *Store) VisitNotice(ctx context.Context, visitor, owner string) (created, named bool, err error) {
	if visitor == owner {
		return false, false, nil
	}
	err = s.inTx(ctx, func(tx pgx.Tx) error {
		var optedIn, recent, barred bool
		if err := tx.QueryRow(ctx, `SELECT coalesce((SELECT visits FROM notification_prefs WHERE user_id=$1),false),
  EXISTS(SELECT 1 FROM notifications WHERE recipient_id=$1 AND actor_id=$2 AND event='profile.visited' AND created_at>now()-interval '1 day'),
  interaction_barred($1::uuid,$2::uuid)`, owner, visitor).Scan(&optedIn, &recent, &barred); err != nil {
			return err
		}
		if !optedIn || recent || barred {
			return nil
		}
		policy, err := privacyOf(ctx, tx, visitor)
		if err != nil {
			return err
		}
		rel, err := relationship(ctx, tx, owner, visitor, policy)
		if err != nil {
			return err
		}
		named = rel.Allows(policy.ProfileAudience)
		created = true
		return notify(ctx, tx, owner, visitor, "profile.visited", visitor)
	})
	return created && err == nil, named, err
}
