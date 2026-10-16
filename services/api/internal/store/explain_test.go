package store

import (
	"context"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// explain returns the plan of query inside tx, one line per row.
func explain(t *testing.T, tx pgx.Tx, query string, args ...any) string {
	t.Helper()
	rows, err := tx.Query(context.Background(), "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) "+query, args...)
	if err != nil {
		t.Fatalf("explain: %v", err)
	}
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var line string
		if err = rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		plan = append(plan, line)
	}
	if err = rows.Err(); err != nil {
		t.Fatal(err)
	}
	return strings.Join(plan, "\n")
}

// seedMembers adds n members spread over the box around Bengaluru, each visible in Nearby with a fresh point,
// and a block between the first two. The caller rolls the transaction back.
func seedMembers(t *testing.T, tx pgx.Tx, n int) (viewer string) {
	t.Helper()
	ctx := context.Background()
	for _, q := range []string{
		`CREATE TEMP TABLE seeded AS SELECT gen_random_uuid() AS id, g FROM generate_series(1,` + strconv.Itoa(n) + `) g`,
		`INSERT INTO users(user_id) SELECT id FROM seeded`,
		`INSERT INTO nearby_prefs(user_id,visible) SELECT id,true FROM seeded`,
		`INSERT INTO user_locations(user_id,latitude,longitude,updated_at) SELECT id, 12.0+random()*3, 77.0+random()*3, now() FROM seeded`,
		`ANALYZE user_locations`,
		// Without statistics for nearby_prefs the planner drives the join from it on a database that has not seen
		// 20000 rows before (a fresh one, as in CI) and never reaches the GiST index.
		`ANALYZE nearby_prefs`,
	} {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	if err := tx.QueryRow(ctx, `SELECT id::text FROM seeded WHERE g=1`).Scan(&viewer); err != nil {
		t.Fatal(err)
	}
	return viewer
}

// Nearby reads its candidates through the GiST index (audit D16), with the bounding box and the nearest-first
// candidate cap, and the block check of a list is a hashed subplan, not one function call per row (audit D9).
func TestNearbyUsesGistIndexAndHashedBlocks(t *testing.T) {
	s := opsTestStore(t)
	ctx := context.Background()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	viewer := seedMembers(t, tx, 20000)
	box := domain.NearbyBox(domain.Location{Latitude: 13.5, Longitude: 78.5}, 5)
	for _, tc := range []struct {
		name, query string
		box         domain.BoundingBox
	}{{"box", nearbySQL, box}, {"wrapped box", nearbyWrapSQL, domain.BoundingBox{LatMin: 13, LatMax: 14, LonLimited: true, Wrap: true, LonMin: 179, LonMax: -179}}} {
		args := append([]any{viewer, 13.5, 78.5, 5.0, tc.box.LatMin, tc.box.LatMax, tc.box.LonLimited, tc.box.Wrap, tc.box.LonMin, tc.box.LonMax, 0, "00000000-0000-0000-0000-000000000000", 20, 24}, peopleFilterArgs(domain.PeopleFilters{}).list()...)
		args = append(args, false)
		plan := explain(t, tx, tc.query, args...)
		t.Logf("Nearby, %s, 20000 stored points:\n%s", tc.name, plan)
		if !strings.Contains(plan, "user_locations_point_gist") {
			t.Errorf("%s: the plan does not use the GiST index:\n%s", tc.name, plan)
		}
		if strings.Contains(plan, "Seq Scan on user_locations") {
			t.Errorf("%s: the plan scans every stored point:\n%s", tc.name, plan)
		}
		if !strings.Contains(plan, "hashed SubPlan") {
			t.Errorf("%s: the block check is not a hashed subplan:\n%s", tc.name, plan)
		}
	}
}
