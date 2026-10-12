package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

func TestProfileStatsSourceAndVisibility(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	ctx := context.Background()
	db, err := store.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Pool.Close()
	var name string
	if err = db.Pool.QueryRow(ctx, "SELECT current_database()").Scan(&name); err != nil || name != "hiyall_test" {
		t.Fatal("requires dedicated hiyall_test DB")
	}
	if _, err = db.Pool.Exec(ctx, "TRUNCATE users,auth_identities,profiles,privacy_settings,sessions,blocks,outbox_events CASCADE"); err != nil {
		t.Fatal(err)
	}
	if err = db.Seed(ctx); err != nil {
		t.Fatal(err)
	}
	// The counts audience defaults to everyone; this test starts from "nobody" to prove each step of the change.
	if _, err = db.Pool.Exec(ctx, `UPDATE privacy_settings SET data=jsonb_set(data,'{fieldAudiences,counts}','"nobody"')`); err != nil {
		t.Fatal(err)
	}
	// Only integration fixtures: pending/removed edges and inactive peers must not count.
	if _, err = db.Pool.Exec(ctx, `
 INSERT INTO users(user_id,status) VALUES
 ('019a4000-0000-7000-8000-000000000003','active'),
 ('019a4000-0000-7000-8000-000000000004','suspended');
 INSERT INTO friendships(friendship_id,user_low_id,user_high_id,requested_by,status) VALUES
 ('019a5000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000002','019a4000-0000-7000-8000-000000000002','accepted'),
 ('019a5000-0000-7000-8000-000000000002','019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000003','019a4000-0000-7000-8000-000000000001','pending'),
 ('019a5000-0000-7000-8000-000000000003','019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000004','019a4000-0000-7000-8000-000000000001','accepted');
 INSERT INTO follows(follower_id,followee_id,state) VALUES
 ('019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000002','active'),
 ('019a4000-0000-7000-8000-000000000002','019a4000-0000-7000-8000-000000000001','active'),
 ('019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000003','pending'),
 ('019a4000-0000-7000-8000-000000000003','019a4000-0000-7000-8000-000000000001','removed'),
 ('019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000004','active'),
 ('019a4000-0000-7000-8000-000000000004','019a4000-0000-7000-8000-000000000001','active');
 UPDATE profiles SET data=data || '{"socialStats":{"friends":999,"following":999,"followers":999}}'::jsonb;
 `); err != nil {
		t.Fatal(err)
	}
	assertStats := func(id string, want int64) {
		t.Helper()
		p, err := db.GetProfile(ctx, id, nil)
		if err != nil {
			t.Fatal(err)
		}
		expected := domain.SocialStats{Friends: want, Following: want, Followers: want}
		if p.SocialStats == nil || *p.SocialStats != expected {
			t.Fatalf("stats=%+v want=%+v", p.SocialStats, expected)
		}
	}
	assertStats(alice, 1)
	assertStats(bob, 1)
	patch := func(raw string) map[string]json.RawMessage {
		var v map[string]json.RawMessage
		if err := json.Unmarshal([]byte(raw), &v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	if _, err = db.UpdateProfile(ctx, bob, 1, patch(`{"quote":"Small moments matter.","profileAudience":"public"}`), nil); err != nil {
		t.Fatal(err)
	}
	visible, err := db.VisibleProfile(ctx, alice, bob, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := visible["socialStats"]; ok {
		t.Fatal("private counts leaked")
	}
	if visible["quote"] != "Small moments matter." {
		t.Fatal("quote not persisted")
	}
	if _, err = db.UpdatePrivacy(ctx, bob, 2, patch(`{"fieldAudiences":{"counts":"everyone"}}`)); err != nil {
		t.Fatal(err)
	}
	visible, err = db.VisibleProfile(ctx, alice, bob, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if visible["socialStats"] != (domain.SocialStats{Friends: 1, Following: 1, Followers: 1}) {
		t.Fatalf("wrong public counts: %+v", visible["socialStats"])
	}
	if _, err = db.UpdatePrivacy(ctx, bob, 3, patch(`{"fieldAudiences":{"counts":"nobody"}}`)); err != nil {
		t.Fatal(err)
	}
	visible, err = db.VisibleProfile(ctx, alice, bob, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := visible["socialStats"]; ok {
		t.Fatal("count privacy revocation ignored")
	}
	if err = db.SetBlock(ctx, bob, alice, true); err != nil {
		t.Fatal(err)
	}
	assertStats(alice, 0)
	assertStats(bob, 0)
	if _, err = db.VisibleProfile(ctx, alice, bob, nil, nil); !errors.Is(err, domain.ErrNotFound) {
		t.Fatal("block did not deny profile")
	}
	// Blocking ends the relationships; unblocking does not silently restore them.
	if err = db.SetBlock(ctx, bob, alice, false); err != nil {
		t.Fatal(err)
	}
	assertStats(alice, 0)
	if _, err = db.Pool.Exec(ctx, `UPDATE users SET status='deactivated' WHERE user_id=$1`, bob); err != nil {
		t.Fatal(err)
	}
	assertStats(alice, 0)
	if _, err = db.UpdateProfile(ctx, alice, 1, patch(`{"socialStats":{"friends":1000}}`), nil); err == nil {
		t.Fatal("client can forge counts")
	}
}
