package store

import (
	"context"
	"errors"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"hiyall/services/api/internal/domain"
)

// Profile v2 (docs/api/25-profile-and-discovery-v2.md): the photo gallery, the recent-visitor and
// places-visited lists, and the filters the server resolves for the viewer.

// ---- Gallery

// profilePhotos is the gallery of user in order, with signed URLs. A photo that is not ready (removed by an
// operator, say) is left out; the rows themselves are tidied by the next gallery write.
func profilePhotos(ctx context.Context, q querier, user string, sign Signer) ([]domain.ProfilePhoto, error) {
	rows, err := q.Query(ctx, `SELECT m.media_id::text,m.variants->>'full',m.variants->>'thumb',coalesce(m.width,0),coalesce(m.height,0)
 FROM profile_photos pp JOIN media_assets m ON m.media_id=pp.media_id AND m.owner_id=pp.user_id AND m.status='ready'
 WHERE pp.user_id=$1 ORDER BY pp.position`, user)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.ProfilePhoto{}
	for rows.Next() {
		var p domain.ProfilePhoto
		var full, thumb *string
		if err = rows.Scan(&p.MediaID, &full, &thumb, &p.Width, &p.Height); err != nil {
			return nil, err
		}
		if u := avatarURL(sign, full); u != nil {
			p.URL = *u
		}
		if u := avatarURL(sign, thumb); u != nil {
			p.ThumbURL = *u
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ProfilePhotos is the caller's own gallery.
func (s *Store) ProfilePhotos(ctx context.Context, id string, sign Signer) ([]domain.ProfilePhoto, error) {
	return profilePhotos(ctx, s.Pool, id, sign)
}

// galleryIDs is the media ids of a member's gallery in order, as stored (rows of photos that are no longer ready
// included, so the caller can tidy them).
func galleryIDs(ctx context.Context, tx pgx.Tx, user string) ([]string, error) {
	rows, err := tx.Query(ctx, `SELECT pp.media_id::text FROM profile_photos pp
 JOIN media_assets m ON m.media_id=pp.media_id AND m.status='ready' WHERE pp.user_id=$1 ORDER BY pp.position`, user)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// writeGallery replaces the stored order with ids (renumbered from 0, rows of photos that are gone dropped) and
// mirrors the first photo into the profile's avatarMediaId, in the caller's transaction. The profile row and the
// account row must be locked by the caller. A change of the first photo bumps the profile version.
func writeGallery(ctx context.Context, tx pgx.Tx, user string, ids []string) error {
	if err := writeGalleryRows(ctx, tx, user, ids); err != nil {
		return err
	}
	var first any
	if len(ids) > 0 {
		first = ids[0]
	}
	_, err := tx.Exec(ctx, `UPDATE profiles SET data=jsonb_set(data,'{avatarMediaId}',coalesce(to_jsonb($2::text),'null'::jsonb)),version=version+1,updated_at=now()
 WHERE user_id=$1 AND data->>'avatarMediaId' IS DISTINCT FROM $2::text`, user, first)
	return err
}

// writeGalleryRows replaces the stored order with ids, renumbered from 0.
func writeGalleryRows(ctx context.Context, tx pgx.Tx, user string, ids []string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM profile_photos WHERE user_id=$1`, user); err != nil {
		return err
	}
	for i, id := range ids {
		if _, err := tx.Exec(ctx, `INSERT INTO profile_photos(user_id,position,media_id) VALUES($1,$2,$3)`, user, i, id); err != nil {
			return mapped(err)
		}
	}
	return nil
}

// releasePhoto marks a photo that left the gallery deleted; the media cleanup removes its objects.
func releasePhoto(ctx context.Context, tx pgx.Tx, owner, mediaID string) error {
	_, err := tx.Exec(ctx, `UPDATE media_assets SET status='deleted',deleted_at=now() WHERE media_id=$1 AND owner_id=$2 AND purpose='avatar' AND status<>'deleted'`, mediaID, owner)
	return err
}

// lockMember takes the account and profile row locks every profile write takes, so two gallery or profile writes
// of one member run one after the other.
func lockMember(ctx context.Context, tx pgx.Tx, id string) error {
	var active bool
	if err := tx.QueryRow(ctx, `SELECT status='active' FROM users WHERE user_id=$1 FOR NO KEY UPDATE`, id).Scan(&active); err != nil {
		return mapped(err)
	} else if !active {
		return domain.ErrNotFound
	}
	var one int
	return mapped(tx.QueryRow(ctx, `SELECT 1 FROM profiles WHERE user_id=$1 FOR NO KEY UPDATE`, id).Scan(&one))
}

func claimGalleryPhoto(ctx context.Context, tx pgx.Tx, id, mediaID string) error {
	err := claimMedia(ctx, tx, id, "avatar", []string{mediaID})
	if errors.Is(err, domain.ErrMediaNotReady) {
		return &domain.ValidationError{Field: "mediaId", Message: "upload your photo and finish the upload first"}
	}
	return err
}

// AddProfilePhoto appends a ready, unattached photo of the member's to the end of the gallery. At most
// e.ProfilePhotosMax photos fit (domain.ErrPhotosFull). A photo that was quarantined by the upload scanner, is
// still pending, belongs to someone else or is already attached is refused with 422 on mediaId. The first photo
// of an empty gallery becomes the profile photo.
func (s *Store) AddProfilePhoto(ctx context.Context, id, mediaID string, e domain.Entitlements, sign Signer) ([]domain.ProfilePhoto, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockMember(ctx, tx, id); err != nil {
			return err
		}
		ids, err := galleryIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		if len(ids) >= e.ProfilePhotosMax {
			return domain.ErrPhotosFull
		}
		if err = claimGalleryPhoto(ctx, tx, id, mediaID); err != nil {
			return err
		}
		return writeGallery(ctx, tx, id, append(ids, mediaID))
	})
	if err != nil {
		return nil, err
	}
	return s.ProfilePhotos(ctx, id, sign)
}

// ReplaceProfilePhoto puts a new ready, unattached photo in the place of one in the gallery, keeping its position;
// the replaced photo is released for deletion.
func (s *Store) ReplaceProfilePhoto(ctx context.Context, id, oldID, newID string, sign Signer) ([]domain.ProfilePhoto, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockMember(ctx, tx, id); err != nil {
			return err
		}
		ids, err := galleryIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		at := slices.Index(ids, oldID)
		if at < 0 {
			return domain.ErrPhotoNotFound
		}
		if oldID == newID {
			return nil
		}
		if err = claimGalleryPhoto(ctx, tx, id, newID); err != nil {
			return err
		}
		ids[at] = newID
		if err = writeGallery(ctx, tx, id, ids); err != nil {
			return err
		}
		return releasePhoto(ctx, tx, id, oldID)
	})
	if err != nil {
		return nil, err
	}
	return s.ProfilePhotos(ctx, id, sign)
}

// DeleteProfilePhoto removes a photo from the gallery and releases it for deletion. The photos after it move up;
// removing the first makes the next one the profile photo.
func (s *Store) DeleteProfilePhoto(ctx context.Context, id, mediaID string, sign Signer) ([]domain.ProfilePhoto, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockMember(ctx, tx, id); err != nil {
			return err
		}
		ids, err := galleryIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		at := slices.Index(ids, mediaID)
		if at < 0 {
			return domain.ErrPhotoNotFound
		}
		if err = writeGallery(ctx, tx, id, slices.Delete(ids, at, at+1)); err != nil {
			return err
		}
		return releasePhoto(ctx, tx, id, mediaID)
	})
	if err != nil {
		return nil, err
	}
	return s.ProfilePhotos(ctx, id, sign)
}

// ReorderProfilePhotos sets the order of the gallery. order must name exactly the photos in it, once each.
func (s *Store) ReorderProfilePhotos(ctx context.Context, id string, order []string, sign Signer) ([]domain.ProfilePhoto, error) {
	err := s.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockMember(ctx, tx, id); err != nil {
			return err
		}
		ids, err := galleryIDs(ctx, tx, id)
		if err != nil {
			return err
		}
		if len(order) != len(ids) {
			return &domain.ValidationError{Field: "mediaIds", Message: "list every photo in your gallery exactly once"}
		}
		seen := map[string]bool{}
		for _, m := range order {
			if seen[m] || !slices.Contains(ids, m) {
				return &domain.ValidationError{Field: "mediaIds", Message: "list every photo in your gallery exactly once"}
			}
			seen[m] = true
		}
		return writeGallery(ctx, tx, id, order)
	})
	if err != nil {
		return nil, err
	}
	return s.ProfilePhotos(ctx, id, sign)
}

// ---- Filters the server resolves for the viewer

// viewerCountry is the country on the viewer's own profile ("" when none is set).
func (s *Store) viewerCountry(ctx context.Context, viewer string) (string, error) {
	var country *string
	err := s.Pool.QueryRow(ctx, `SELECT data->>'country' FROM profiles WHERE user_id=$1`, viewer).Scan(&country)
	if errors.Is(err, pgx.ErrNoRows) || country == nil {
		return "", nil
	}
	return *country, err
}

// resolveFilters turns the "same country" shortcut into the viewer's own country. The result is what the
// queries read; f is not changed.
func (s *Store) resolveFilters(ctx context.Context, viewer string, f domain.PeopleFilters) (domain.PeopleFilters, error) {
	if !f.SameCountry {
		return f, nil
	}
	country, err := s.viewerCountry(ctx, viewer)
	if err != nil {
		return f, err
	}
	if country == "" {
		return f, domain.ErrSameCountryUnknown
	}
	f.Country, f.SameCountry = country, false
	return f, nil
}

// ---- Visitors

// VisitedPerson is one row of the recent-visitor and places-visited lists: a person and when the visit last
// happened (within the last domain.VisitWindow).
type VisitedPerson struct {
	User      domain.UserSummary `json:"user"`
	VisitedAt time.Time          `json:"visitedAt"`
	// Following is the caller's own follow state on the person (none, pending, active).
	Following string `json:"following"`
}

// minorSQL is true when member column x is under 18 (no birth date is an adult), the same rule as age_band.
func minorSQL(x string) string {
	return `coalesce((SELECT birth_date>(now() AT TIME ZONE 'UTC')::date-interval '18 years' FROM member_ages WHERE user_id=` + x + `),false)`
}

// CanSeeVisitors says whether viewer may read the recent-visitor list of target. It is open only when the target
// is an adult who turned "let people see who visited me" on, and viewer may open the target's profile (not blocked,
// same age band, the profile's audience admits them). Anything else is ErrNotFound (barred, unknown, inactive) or
// ErrVisitorsPrivate. A minor's list is never available, whatever their stored setting says. The owner reads their
// own through ListVisitors, not this.
func (s *Store) CanSeeVisitors(ctx context.Context, viewer, target string) error {
	if viewer == target {
		return domain.ErrVisitorsPrivate
	}
	var visible, minor bool
	if err := s.Pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users u JOIN onboarding o USING(user_id) WHERE u.user_id=$2 AND u.status='active' AND o.completed_at IS NOT NULL) AND NOT `+barredBetween+`,`+minorSQL("$2::uuid"), viewer, target).Scan(&visible, &minor); err != nil {
		return err
	}
	if !visible {
		return domain.ErrNotFound
	}
	policy, err := privacyOf(ctx, s.Pool, target)
	if err != nil {
		return err
	}
	rel, err := relationship(ctx, s.Pool, viewer, target, policy)
	if err != nil {
		return err
	}
	if !rel.Allows(policy.ProfileAudience) || minor || !policy.VisitorsVisibleToOthers {
		return domain.ErrVisitorsPrivate
	}
	return nil
}

// ListRecentVisitors pages the members who opened target's profile in the last domain.VisitWindow, most recent
// visit first, at most domain.VisitListMax in all, for a viewer CanSeeVisitors admitted. Visitors who are
// inactive, under 18, or barred from the viewer or from the target (blocks in either direction, the other age
// band) are left out.
func (s *Store) ListRecentVisitors(ctx context.Context, viewer, target string, before *time.Time, beforeID string, limit int, sign Signer) ([]VisitedPerson, error) {
	rows, err := s.Pool.Query(ctx, `WITH v AS (
  SELECT pv.visitor_id,pv.last_visited_at FROM profile_visits pv
  JOIN users u ON u.user_id=pv.visitor_id AND u.status='active'
  JOIN onboarding o ON o.user_id=pv.visitor_id AND o.completed_at IS NOT NULL
  WHERE pv.profile_id=$2 AND pv.last_visited_at>now()-$6::interval
  AND NOT `+minorSQL("pv.visitor_id")+` AND `+notBarred("$2::uuid", "pv.visitor_id")+` AND `+notBarred("$1::uuid", "pv.visitor_id")+`
  ORDER BY pv.last_visited_at DESC,pv.visitor_id DESC LIMIT $7)
 SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`,v.last_visited_at,coalesce(vf.state,'none') FROM v
 JOIN profiles p ON p.user_id=v.visitor_id`+avatarJoin("av", "p")+`
 LEFT JOIN follows vf ON vf.follower_id=$1 AND vf.followee_id=v.visitor_id AND vf.state<>'removed'
 WHERE ($3::timestamptz IS NULL OR (v.last_visited_at,v.visitor_id)<($3,$4::uuid))
 ORDER BY v.last_visited_at DESC,v.visitor_id DESC LIMIT $5`, viewer, target, before, beforeID, limit, domain.VisitWindow, domain.VisitListMax)
	if err != nil {
		return nil, err
	}
	return scanVisited(rows, sign)
}

// ListPlacesVisited pages the profiles the member opened in the last domain.VisitWindow, most recent first, at
// most domain.VisitListMax. It is the member's own history and is never readable by anyone else. People who are
// inactive or barred from the member now (blocks, the other age band) are left out.
func (s *Store) ListPlacesVisited(ctx context.Context, user string, before *time.Time, beforeID string, limit int, sign Signer) ([]VisitedPerson, error) {
	rows, err := s.Pool.Query(ctx, `WITH v AS (
  SELECT pv.profile_id,pv.last_visited_at FROM profile_visits pv
  JOIN users u ON u.user_id=pv.profile_id AND u.status='active'
  JOIN onboarding o ON o.user_id=pv.profile_id AND o.completed_at IS NOT NULL
  WHERE pv.visitor_id=$1 AND pv.last_visited_at>now()-$5::interval AND `+notBarred("$1::uuid", "pv.profile_id")+`
  ORDER BY pv.last_visited_at DESC,pv.profile_id DESC LIMIT $6)
 SELECT p.user_id::text,p.username,coalesce(p.data->>'displayName',''),`+avatarThumbKey("av")+`,v.last_visited_at,coalesce(vf.state,'none') FROM v
 JOIN profiles p ON p.user_id=v.profile_id`+avatarJoin("av", "p")+`
 LEFT JOIN follows vf ON vf.follower_id=$1 AND vf.followee_id=v.profile_id AND vf.state<>'removed'
 WHERE ($2::timestamptz IS NULL OR (v.last_visited_at,v.profile_id)<($2,$3::uuid))
 ORDER BY v.last_visited_at DESC,v.profile_id DESC LIMIT $4`, user, before, beforeID, limit, domain.VisitWindow, domain.VisitListMax)
	if err != nil {
		return nil, err
	}
	return scanVisited(rows, sign)
}

// ClearPlacesVisited deletes the member's own visit history: the rows that say which profiles they opened. The
// all-time visitor counts of those profiles are not lowered. It returns how many places were cleared.
func (s *Store) ClearPlacesVisited(ctx context.Context, user string) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM profile_visits WHERE visitor_id=$1`, user)
	return tag.RowsAffected(), err
}

func scanVisited(rows pgx.Rows, sign Signer) ([]VisitedPerson, error) {
	defer rows.Close()
	result := []VisitedPerson{}
	for rows.Next() {
		var v VisitedPerson
		var avatar *string
		if err := rows.Scan(&v.User.UserID, &v.User.Username, &v.User.DisplayName, &avatar, &v.VisitedAt, &v.Following); err != nil {
			return nil, err
		}
		v.User.AvatarURL = avatarURL(sign, avatar)
		result = append(result, v)
	}
	return result, rows.Err()
}
