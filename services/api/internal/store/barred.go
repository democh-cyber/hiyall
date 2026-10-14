package store

// notBarred is interaction_barred (migration 0017) written for list queries (audit D9): true when viewer and
// other may see and reach each other. interaction_barred is an opaque function that runs, per candidate row, two
// block lookups, two birth-date lookups and a settings read, the viewer's own among them. This form lets the
// planner do the viewer's half once per statement:
//
//   - the blocks are one hashed subplan, "other NOT IN (members the viewer blocked or who blocked the viewer)",
//     built once and probed per row;
//   - the viewer's band and the isolation switch are scalar subselects with no reference to the row, so they are
//     InitPlans evaluated once;
//   - only the other member's band is looked up per row (one primary key probe of member_ages).
//
// viewer must be an expression that does not depend on the row (a parameter such as "$1::uuid"); other is the
// member column or expression. It never answers differently from NOT interaction_barred(viewer, other): a
// missing birth date is an adult, and a NULL other is not barred (the coalesce), as before. Single-row checks
// keep calling interaction_barred, which is cheaper for one row; chat keeps it everywhere.
func notBarred(viewer, other string) string {
	const minor = `birth_date>(now() AT TIME ZONE 'UTC')::date-interval '18 years'`
	return `(coalesce((` + other + `) NOT IN (SELECT blocked_id FROM blocks WHERE blocker_id=` + viewer + ` UNION ALL SELECT blocker_id FROM blocks WHERE blocked_id=` + viewer + `),true)
 AND (NOT (SELECT age_isolation_enabled()) OR (SELECT coalesce((SELECT ` + minor + ` FROM member_ages WHERE user_id=` + viewer + `),false))
   =coalesce((SELECT ` + minor + ` FROM member_ages WHERE user_id=` + other + `),false)))`
}
