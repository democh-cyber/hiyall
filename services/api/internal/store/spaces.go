package store

import (
	"context"
	"github.com/jackc/pgx/v5"
	"kairova/services/api/internal/domain"
	"strings"
	"time"
)

var ErrSpaceClosed = &domain.PolicyError{Status: 409, Code: "SPACE_CLOSED", Message: "This space is read-only now"}
var ErrSpaceFull = &domain.PolicyError{Status: 409, Code: "SPACE_FULL", Message: "This space has reached its capacity"}
var ErrSpaceRole = &domain.PolicyError{Status: 403, Code: "SPACE_ROLE_REQUIRED", Message: "This action needs a host or moderator"}
var ErrSpaceMember = &domain.PolicyError{Status: 403, Code: "SPACE_MEMBER_REQUIRED", Message: "Join this space to take part"}

// Eligibility is rechecked for every read and write, including the host. The
// parent predicate also hides child spaces when community access is lost.
func adultSQL(id string) string {
	return `EXISTS(SELECT 1 FROM discovery_eligibility ae JOIN users au USING(user_id) WHERE ae.user_id=` + id + ` AND au.status='active' AND ae.age_group='adult' AND ae.confirmed_at<=statement_timestamp() AND ae.valid_until>statement_timestamp())`
}
func unblockedSQL(a, b string) string {
	return `NOT EXISTS(SELECT 1 FROM blocks bl WHERE (bl.blocker_id=` + a + ` AND bl.blocked_id=` + b + `) OR (bl.blocker_id=` + b + ` AND bl.blocked_id=` + a + `))`
}
func spaceVisible() string {
	return adultSQL("$1::uuid") + ` AND ` + adultSQL("s.owner_id") + ` AND ` + unblockedSQL("$1::uuid", "s.owner_id") + `
 AND coalesce(m.state,'')<>'banned' AND (s.visibility<>'invite' OR m.state IN ('active','invited'))
 AND (s.parent_id IS NULL OR EXISTS(SELECT 1 FROM space_members pm JOIN spaces ps ON ps.space_id=pm.space_id WHERE pm.space_id=s.parent_id AND pm.user_id=$1 AND pm.state='active' AND ` + adultSQL("ps.owner_id") + ` AND ` + unblockedSQL("$1::uuid", "ps.owner_id") + `))`
}

const spaceSelect = `SELECT s.space_id::text,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),s.kind,s.title,s.description,s.rules,s.visibility,s.parent_id::text,s.capacity,s.starts_at,s.ends_at,s.timezone,
 CASE WHEN s.visibility='public' OR m.state='active' THEN s.location ELSE '' END,
 s.status,s.member_count,coalesce(m.role,''),coalesce(m.state,''),coalesce(m.rsvp,''),
 coalesce((m.state='active' AND s.status='open' AND (s.kind<>'moment' OR (statement_timestamp()>=s.starts_at AND statement_timestamp()<s.ends_at)) AND (s.kind<>'event' OR statement_timestamp()<s.ends_at)),false),s.created_at
 FROM spaces s JOIN profiles p ON p.user_id=s.owner_id LEFT JOIN space_members m ON m.space_id=s.space_id AND m.user_id=$1 `

func scanSpace(row pgx.Row) (domain.Space, error) {
	var x domain.Space
	err := row.Scan(&x.SpaceID, &x.Owner.UserID, &x.Owner.Username, &x.Owner.DisplayName, &x.Kind, &x.Title, &x.Description, &x.Rules, &x.Visibility, &x.ParentID, &x.Capacity, &x.StartsAt, &x.EndsAt, &x.Timezone, &x.Location, &x.Status, &x.MemberCount, &x.MyRole, &x.MyState, &x.MyRSVP, &x.CanDiscuss, &x.CreatedAt)
	return x, err
}

// Lock separately from authorization so a writer waiting on another mutation
// reads membership/roles in a fresh READ COMMITTED statement after the wait.
func lockedSpace(ctx context.Context, tx pgx.Tx, user, id string) (domain.Space, error) {
	var locked string
	if err := tx.QueryRow(ctx, `SELECT space_id::text FROM spaces WHERE space_id=$1 FOR UPDATE`, id).Scan(&locked); err != nil {
		return domain.Space{}, mapped(err)
	}
	x, err := scanSpace(tx.QueryRow(ctx, spaceSelect+` WHERE s.space_id=$2 AND `+spaceVisible(), user, id))
	return x, mapped(err)
}
func (s *Store) Space(ctx context.Context, user, id string) (domain.Space, error) {
	x, err := scanSpace(s.Pool.QueryRow(ctx, spaceSelect+` WHERE s.space_id=$2 AND `+spaceVisible(), user, id))
	return x, mapped(err)
}
func (s *Store) Spaces(ctx context.Context, user, kind, parent string, mine bool, before *time.Time, id string, limit int) ([]domain.Space, error) {
	query := spaceSelect
	if mine {
		query = strings.Replace(query, "LEFT JOIN space_members m", "JOIN space_members m", 1)
	}
	membership := ""
	if mine {
		membership = " AND m.state='active'"
	}
	rows, err := s.Pool.Query(ctx, query+` WHERE s.kind=$2 AND ($3='' OR s.parent_id=nullif($3,'')::uuid)`+membership+` AND `+spaceVisible()+` AND ($4::timestamptz IS NULL OR (s.created_at,s.space_id)<($4,$5::uuid)) ORDER BY s.created_at DESC,s.space_id DESC LIMIT $6`, user, kind, parent, before, id, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (domain.Space, error) { return scanSpace(r) })
}
func (s *Store) CreateSpace(ctx context.Context, user string, in domain.NewSpace) (domain.Space, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Space{}, err
	}
	defer tx.Rollback(ctx)
	// Serialize per-host limits without locking other hosts.
	if _, err = tx.Exec(ctx, `SELECT user_id FROM users WHERE user_id=$1 FOR UPDATE`, user); err != nil {
		return domain.Space{}, err
	}
	var adult bool
	if err = tx.QueryRow(ctx, `SELECT `+adultSQL("$1::uuid"), user).Scan(&adult); err != nil {
		return domain.Space{}, err
	}
	if !adult {
		return domain.Space{}, domain.ErrNotFound
	}
	var count int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM spaces WHERE owner_id=$1 AND status='open' AND (ends_at IS NULL OR ends_at>now())`, user).Scan(&count); err != nil {
		return domain.Space{}, err
	}
	if count >= 50 {
		return domain.Space{}, &domain.PolicyError{Status: 429, Code: "RATE_LIMITED", Message: "Close an existing space before creating another"}
	}
	if in.ParentID != nil {
		parent, e := lockedSpace(ctx, tx, user, *in.ParentID)
		if e != nil {
			return domain.Space{}, mapped(e)
		}
		if parent.Kind != "community" || parent.MyState != "active" || (parent.MyRole != "owner" && parent.MyRole != "admin") {
			return domain.Space{}, ErrSpaceRole
		}
		if parent.Status != "open" {
			return domain.Space{}, ErrSpaceClosed
		}
		if parent.Visibility != "public" && in.Visibility == "public" {
			return domain.Space{}, &domain.ValidationError{Field: "visibility", Message: "children of private communities cannot be public"}
		}
	}
	id := newID()
	_, err = tx.Exec(ctx, `INSERT INTO spaces(space_id,owner_id,parent_id,kind,title,description,rules,visibility,capacity,starts_at,ends_at,timezone,location) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`, id, user, in.ParentID, in.Kind, in.Title, in.Description, in.Rules, in.Visibility, in.Capacity, in.StartsAt, in.EndsAt, in.Timezone, in.Location)
	if err != nil {
		return domain.Space{}, err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO space_members(space_id,user_id,role,state) VALUES($1,$2,'owner','active')`, id, user); err != nil {
		return domain.Space{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return domain.Space{}, err
	}
	return s.Space(ctx, user, id)
}
func host(role string) bool      { return role == "owner" || role == "admin" }
func moderator(role string) bool { return host(role) || role == "moderator" }

// Every membership change locks the space first, so capacity and counters
// cannot drift with simultaneous joins, approvals and removals.
func (s *Store) ChangeSpaceMember(ctx context.Context, user, id, target, action, rsvp string) (domain.Space, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Space{}, err
	}
	defer tx.Rollback(ctx)
	x, err := lockedSpace(ctx, tx, user, id)
	if err != nil {
		return x, mapped(err)
	}
	var role, state, previousRSVP string
	err = tx.QueryRow(ctx, `SELECT role,state,rsvp FROM space_members WHERE space_id=$1 AND user_id=$2`, id, target).Scan(&role, &state, &previousRSVP)
	if err != nil && err != pgx.ErrNoRows {
		return x, err
	}
	if target == user && action != "join" && action != "leave" {
		return x, ErrSpaceRole
	}
	if target != user && (!moderator(x.MyRole) || x.MyState != "active") {
		return x, ErrSpaceRole
	}
	if role == "owner" && action != "join" {
		return x, &domain.PolicyError{Status: 409, Code: "SPACE_OWNER", Message: "The owner must keep their membership"}
	}
	if target != user && (role == "admin" && x.MyRole != "owner" || role == "moderator" && !host(x.MyRole)) {
		return x, ErrSpaceRole
	}
	if action != "join" && previousRSVP != "" {
		rsvp = previousRSVP
	}
	next, newRole := state, role
	if newRole == "" {
		newRole = "member"
	}
	switch action {
	case "join":
		if user != target {
			return x, ErrSpaceRole
		}
		if state == "banned" {
			return x, domain.ErrNotFound
		}
		if state == "active" {
			next = "active"
		} else if x.Visibility == "public" || state == "invited" {
			next = "active"
		} else if x.Visibility == "private" {
			next = "pending"
		} else {
			return x, domain.ErrNotFound
		}
	case "leave":
		if user != target {
			return x, ErrSpaceRole
		}
		next = ""
	case "approve":
		if state != "pending" {
			return x, domain.ErrNotFound
		}
		next = "active"
	case "invite":
		if !host(x.MyRole) {
			return x, ErrSpaceRole
		}
		if state == "banned" {
			return x, domain.ErrNotFound
		}
		if state != "active" {
			next = "invited"
		}
	case "remove":
		next = ""
	case "ban":
		next = "banned"
	case "unban":
		if state != "banned" {
			return x, domain.ErrNotFound
		}
		next = ""
	case "admin", "moderator", "member":
		if !host(x.MyRole) || action == "admin" && x.MyRole != "owner" || state != "active" {
			return x, ErrSpaceRole
		}
		newRole = action
	default:
		return x, domain.ErrNotFound
	}
	if next == "active" || next == "invited" || next == "pending" {
		var eligible bool
		err = tx.QueryRow(ctx, `SELECT `+adultSQL("$1::uuid")+` AND `+unblockedSQL("$1::uuid", "$2::uuid"), target, x.Owner.UserID).Scan(&eligible)
		if err != nil {
			return x, err
		}
		if !eligible {
			return x, domain.ErrNotFound
		}
		if x.ParentID != nil {
			var parent bool
			err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM space_members WHERE space_id=$1 AND user_id=$2 AND state='active')`, *x.ParentID, target).Scan(&parent)
			if err != nil {
				return x, err
			}
			if !parent {
				return x, ErrSpaceMember
			}
		}
	}
	if (action == "join" && state != "active") || action == "invite" || action == "approve" {
		if x.Status != "open" || x.EndsAt != nil && !x.EndsAt.After(time.Now()) {
			return x, ErrSpaceClosed
		}
	}
	if next == "active" && state != "active" {
		if x.Status != "open" || x.EndsAt != nil && !x.EndsAt.After(time.Now()) {
			return x, ErrSpaceClosed
		}
		if x.MemberCount >= x.Capacity {
			return x, ErrSpaceFull
		}
	}
	if (next == "pending" || next == "invited") && next != state {
		var n int
		err = tx.QueryRow(ctx, `SELECT count(*) FROM space_members WHERE space_id=$1 AND state IN ('pending','invited')`, id).Scan(&n)
		if err != nil {
			return x, err
		}
		if n >= 1000 {
			return x, ErrSpaceFull
		}
	}
	if next == "" {
		_, err = tx.Exec(ctx, `DELETE FROM space_members WHERE space_id=$1 AND user_id=$2`, id, target)
	} else {
		_, err = tx.Exec(ctx, `INSERT INTO space_members(space_id,user_id,role,state,rsvp) VALUES($1,$2,$3,$4,$5) ON CONFLICT(space_id,user_id) DO UPDATE SET role=excluded.role,state=excluded.state,rsvp=excluded.rsvp`, id, target, newRole, next, rsvp)
	}
	if err != nil {
		return x, err
	}
	delta := 0
	if state == "active" && next != "active" {
		delta = -1
	}
	if state != "active" && next == "active" {
		delta = 1
	}
	if _, err = tx.Exec(ctx, `UPDATE spaces SET member_count=member_count+$2 WHERE space_id=$1`, id, delta); err != nil {
		return x, err
	}
	if next != state {
		recipient, actor, event := "", "", ""
		switch {
		case next == "pending":
			recipient, actor, event = x.Owner.UserID, user, "space.requested"
		case next == "invited":
			recipient, actor, event = target, user, "space.invited"
		case action == "approve":
			recipient, actor, event = target, user, "space.approved"
		}
		if recipient != "" && recipient != actor {
			if err = notify(ctx, tx, recipient, actor, event, id); err != nil {
				return x, err
			}
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return x, err
	}
	if action == "leave" {
		x.MyState = ""
		x.MyRole = ""
		x.CanDiscuss = false
		x.MemberCount += delta
		return x, nil
	}
	return s.Space(ctx, user, id)
}
func (s *Store) SetSpaceStatus(ctx context.Context, user, id, status string) (domain.Space, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Space{}, err
	}
	defer tx.Rollback(ctx)
	x, err := lockedSpace(ctx, tx, user, id)
	if err != nil {
		return x, err
	}
	if !host(x.MyRole) || x.MyState != "active" {
		return x, ErrSpaceRole
	}
	if _, err = tx.Exec(ctx, `UPDATE spaces SET status=$2 WHERE space_id=$1`, id, status); err != nil {
		return x, err
	}
	if err = tx.Commit(ctx); err != nil {
		return x, err
	}
	return s.Space(ctx, user, id)
}
func (s *Store) SpaceMembers(ctx context.Context, user, id, state string, before *time.Time, beforeID string, limit int) ([]domain.SpaceMember, error) {
	x, err := s.Space(ctx, user, id)
	if err != nil {
		return nil, err
	}
	if x.MyState != "active" {
		return nil, ErrSpaceMember
	}
	if state != "active" && !moderator(x.MyRole) {
		return nil, ErrSpaceRole
	}
	rows, err := s.Pool.Query(ctx, `SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),m.role,m.state,m.rsvp,m.created_at FROM space_members m JOIN profiles p ON p.user_id=m.user_id WHERE m.space_id=$2 AND m.state=$3 AND EXISTS(SELECT 1 FROM spaces s LEFT JOIN space_members m ON m.space_id=s.space_id AND m.user_id=$1 WHERE s.space_id=$2 AND m.state='active' AND ($3='active' OR m.role IN ('owner','admin','moderator')) AND `+spaceVisible()+`) AND `+adultSQL("m.user_id")+` AND `+unblockedSQL("$1::uuid", "m.user_id")+` AND ($4::timestamptz IS NULL OR (m.created_at,m.user_id)<($4,$5::uuid)) ORDER BY m.created_at DESC,m.user_id DESC LIMIT $6`, user, id, state, before, beforeID, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (domain.SpaceMember, error) {
		var m domain.SpaceMember
		e := r.Scan(&m.User.UserID, &m.User.Username, &m.User.DisplayName, &m.Role, &m.State, &m.RSVP, &m.CreatedAt)
		return m, e
	})
}
func (s *Store) SpaceEntries(ctx context.Context, user, id string, before *time.Time, beforeID string, limit int) ([]domain.SpaceEntry, error) {
	x, err := s.Space(ctx, user, id)
	if err != nil {
		return nil, err
	}
	if x.MyState != "active" {
		return nil, ErrSpaceMember
	}
	rows, err := s.Pool.Query(ctx, `SELECT e.entry_id::text,p.user_id::text,p.username,coalesce(p.data->>'displayName',''),e.body,e.created_at,(e.author_id=$1 OR $6) FROM space_entries e JOIN profiles p ON p.user_id=e.author_id WHERE e.space_id=$2 AND e.deleted_at IS NULL AND EXISTS(SELECT 1 FROM spaces s LEFT JOIN space_members m ON m.space_id=s.space_id AND m.user_id=$1 WHERE s.space_id=$2 AND m.state='active' AND `+spaceVisible()+`) AND `+adultSQL("e.author_id")+` AND `+unblockedSQL("$1::uuid", "e.author_id")+` AND ($3::timestamptz IS NULL OR (e.created_at,e.entry_id)<($3,$4::uuid)) ORDER BY e.created_at DESC,e.entry_id DESC LIMIT $5`, user, id, before, beforeID, limit, moderator(x.MyRole))
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (domain.SpaceEntry, error) {
		var e domain.SpaceEntry
		err := r.Scan(&e.EntryID, &e.Author.UserID, &e.Author.Username, &e.Author.DisplayName, &e.Body, &e.CreatedAt, &e.CanDelete)
		return e, err
	})
}
func (s *Store) CreateSpaceEntry(ctx context.Context, user, id, body string) (string, error) {
	body = strings.TrimSpace(body)
	if !domain.SpaceText(body, 1, 2000) {
		return "", &domain.ValidationError{Field: "body", Message: "write 1–2000 characters"}
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	x, err := lockedSpace(ctx, tx, user, id)
	if err != nil {
		return "", mapped(err)
	}
	if x.MyState != "active" {
		return "", ErrSpaceMember
	}
	if !x.CanDiscuss {
		return "", ErrSpaceClosed
	}
	entry := newID()
	if _, err = tx.Exec(ctx, `INSERT INTO space_entries(entry_id,space_id,author_id,body) VALUES($1,$2,$3,$4)`, entry, id, user, body); err != nil {
		return "", err
	}
	return entry, tx.Commit(ctx)
}
func (s *Store) DeleteSpaceEntry(ctx context.Context, user, id, entry string) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	x, err := lockedSpace(ctx, tx, user, id)
	if err != nil {
		return err
	}
	if x.MyState != "active" {
		return ErrSpaceMember
	}
	tag, err := tx.Exec(ctx, `UPDATE space_entries SET deleted_at=now() WHERE space_id=$1 AND entry_id=$2 AND deleted_at IS NULL AND (author_id=$3 OR $4)`, id, entry, user, moderator(x.MyRole))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return domain.ErrNotFound
	}
	return tx.Commit(ctx)
}

func (s *Store) InviteSpaceUser(ctx context.Context, user, id, username string) (domain.Space, string, error) {
	x, err := s.Space(ctx, user, id)
	if err != nil {
		return x, "", err
	}
	if !(host(x.MyRole) && x.MyState == "active") {
		return x, "", ErrSpaceRole
	}
	var target string
	err = s.Pool.QueryRow(ctx, `SELECT user_id::text FROM profiles WHERE lower(username)=lower($1)`, strings.TrimPrefix(strings.TrimSpace(username), "@")).Scan(&target)
	if err != nil {
		return x, "", mapped(err)
	}
	x, err = s.ChangeSpaceMember(ctx, user, id, target, "invite", "going")
	return x, target, err
}

// Editing preserves audience and ancestry: widening either would expose prior
// discussions to people who were not part of the original audience.
func (s *Store) UpdateSpace(ctx context.Context, user, id string, in domain.NewSpace) (domain.Space, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return domain.Space{}, err
	}
	defer tx.Rollback(ctx)
	x, err := lockedSpace(ctx, tx, user, id)
	if err != nil {
		return x, mapped(err)
	}
	if !host(x.MyRole) || x.MyState != "active" {
		return x, ErrSpaceRole
	}
	sameParent := x.ParentID == nil && in.ParentID == nil || x.ParentID != nil && in.ParentID != nil && *x.ParentID == *in.ParentID
	if in.Kind != x.Kind || in.Visibility != x.Visibility || !sameParent {
		return x, &domain.ValidationError{Field: "visibility", Message: "kind, audience and parent cannot be changed"}
	}
	if in.Capacity < x.MemberCount {
		return x, &domain.ValidationError{Field: "capacity", Message: "capacity cannot be below the current participant count"}
	}
	_, err = tx.Exec(ctx, `UPDATE spaces SET title=$2,description=$3,rules=$4,capacity=$5,starts_at=$6,ends_at=$7,timezone=$8,location=$9 WHERE space_id=$1`, id, in.Title, in.Description, in.Rules, in.Capacity, in.StartsAt, in.EndsAt, in.Timezone, in.Location)
	if err != nil {
		return x, err
	}
	if err = tx.Commit(ctx); err != nil {
		return x, err
	}
	return s.Space(ctx, user, id)
}
