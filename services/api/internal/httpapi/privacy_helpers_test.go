package httpapi

import (
	"context"
	"testing"

	"hiyall/services/api/internal/store"
)

// closePrivacy puts members back to the closed posture Hiyall had before it
// opened up: friends-only profile, not discoverable, presence hidden and every
// field hidden. Tests that exercise a restriction, or walk an audience from
// closed to open, start here instead of relying on the product defaults. It
// does not touch version numbers.
func closePrivacy(t *testing.T, ctx context.Context, db *store.Store, ids ...string) {
	t.Helper()
	const closedFields = `{"pronouns":"nobody","location":"nobody","profession":"nobody","education":"nobody","website":"nobody","timezone":"nobody","languages":"nobody","interests":"nobody","vibe":"nobody","connections":"nobody"}`
	if _, err := db.Pool.Exec(ctx, `UPDATE privacy_settings SET data=data||jsonb_build_object('profileAudience','friends','discoverable',false,'showInterestOverlap',false,'onlineAudience','nobody','fieldAudiences',$2::jsonb) WHERE user_id::text=ANY($1::text[])`, ids, closedFields); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Pool.Exec(ctx, `UPDATE profiles SET data=jsonb_set(data,'{profileAudience}','"friends"') WHERE user_id::text=ANY($1::text[])`, ids); err != nil {
		t.Fatal(err)
	}
}
