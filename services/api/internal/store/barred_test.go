package store

import (
	"context"
	"testing"
)

// notBarred must agree with NOT interaction_barred for every pair, in both directions, with isolation on and
// off: adults, minors, a member with no birth date, a block either way, and a NULL "other".
func TestNotBarredMatchesInteractionBarred(t *testing.T) {
	s := opsTestStore(t)
	ctx := context.Background()
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	exec(`CREATE TEMP TABLE people(id uuid PRIMARY KEY, label text) ON COMMIT DROP`)
	exec(`INSERT INTO people SELECT gen_random_uuid(), l FROM unnest(ARRAY['adult','adult2','minor','minor2','undated','blocker','blocked']) l`)
	exec(`INSERT INTO users(user_id) SELECT id FROM people`)
	exec(`INSERT INTO member_ages(user_id,birth_date) SELECT id, CASE WHEN label LIKE 'minor%' THEN (now() AT TIME ZONE 'UTC')::date - interval '15 years' ELSE (now() AT TIME ZONE 'UTC')::date - interval '30 years' END FROM people WHERE label<>'undated'`)
	exec(`INSERT INTO blocks(blocker_id,blocked_id) SELECT a.id,b.id FROM people a, people b WHERE a.label='blocker' AND b.label='blocked'`)
	exec(`INSERT INTO blocks(blocker_id,blocked_id) SELECT a.id,b.id FROM people a, people b WHERE a.label='minor2' AND b.label='adult2'`)
	for _, isolation := range []string{"on", "off"} {
		exec(`SELECT set_config('kairova.age_band_isolation', $1, true)`, isolation)
		rows, err := tx.Query(ctx, `SELECT a.label, b.label, NOT interaction_barred(a.id,b.id), `+notBarred("a.id", "b.id")+` FROM people a CROSS JOIN people b`)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for rows.Next() {
			var a, b string
			var want, got bool
			if err = rows.Scan(&a, &b, &want, &got); err != nil {
				t.Fatal(err)
			}
			if got != want {
				t.Errorf("isolation %s: %s -> %s: notBarred=%v, interaction_barred says %v", isolation, a, b, got, !want)
			}
			n++
		}
		rows.Close()
		if n != 49 {
			t.Fatalf("%d pairs", n)
		}
		var nullOther bool
		var want bool
		if err = tx.QueryRow(ctx, `SELECT `+notBarred("p.id", "NULL::uuid")+`, NOT interaction_barred(p.id, NULL::uuid) FROM people p WHERE label='adult'`).Scan(&nullOther, &want); err != nil || nullOther != want {
			t.Errorf("NULL other: %v vs %v (%v)", nullOther, want, err)
		}
	}
}
