package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// Profile and discovery v2 (docs/api/25-profile-and-discovery-v2.md): possible matches, the photo gallery and the
// two visitor lists. The route rows are in router.go.

// ---- Possible matches

// possibleCursor continues a possible-matches list after one person: their score and user id (the keyset), bound to
// the viewer and to the request's options, and short-lived. It is signed with its own key prefix, so a Discover or
// Nearby cursor never opens as one.
type possibleCursor struct {
	User  string `json:"u"`
	Query string `json:"q"`
	Score int    `json:"s"`
	After string `json:"a"`
	Exp   int64  `json:"e"`
	Page  int    `json:"p"`
}

const possibleCursorPrefix = "possible\x00"

// possibleMaxPages bounds how deep one list can be paged (like people search).
const possibleMaxPages = 10

// possibleMatches is POST /v1/discovery/possible-matches {limit?, excludeFollowing?, cursor?} -> {items, nextCursor}.
func (a *API) possibleMatches(w http.ResponseWriter, r *http.Request, p store.Principal) {
	body, err := decode(w, r)
	var req domain.PossibleRequest
	if err == nil {
		req, err = domain.ParsePossibleRequest(body)
	}
	if err != nil {
		a.error(w, r, err)
		return
	}
	ctx := r.Context()
	// A page counts against the day like a search page: a script cannot walk the member base with it.
	if err = a.Store.BumpDaily(ctx, p.UserID, domain.DailySearchPages, a.entitlementsFor(ctx, p.UserID).SearchPagesPerDay); err != nil {
		a.error(w, r, err)
		return
	}
	sum := sha256.Sum256([]byte(map[bool]string{true: "exclude-following", false: "all"}[req.ExcludeFollowing]))
	query := hex.EncodeToString(sum[:8])
	after, page := store.PossibleAfter{}, 0
	if req.Cursor != "" {
		var c possibleCursor
		if !openCursor(a, possibleCursorPrefix, req.Cursor, &c) || c.User != p.UserID || c.Query != query || c.Exp <= time.Now().Unix() ||
			c.Page <= 0 || c.Page >= possibleMaxPages || !isUUID(c.After) || c.Score < 1 || c.Score > domain.MatchMaxScore {
			a.failure(w, r, 422, "INVALID_CURSOR", "Reload possible matches")
			return
		}
		after, page = store.PossibleAfter{HasAfter: true, Score: c.Score, UserID: c.After}, c.Page
	}
	found, err := a.Store.PossibleMatches(ctx, p.UserID, req.ExcludeFollowing, after, req.Limit+1, a.presence, a.signer(ctx))
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if len(found) > req.Limit {
		found = found[:req.Limit]
		if page+1 < possibleMaxPages {
			last := found[len(found)-1]
			next = sealCursor(a, possibleCursorPrefix, possibleCursor{User: p.UserID, Query: query, Score: last.Score, After: last.Item["userId"].(string), Exp: time.Now().Add(15 * time.Minute).Unix(), Page: page + 1})
		}
	}
	items := make([]map[string]any, len(found))
	for i := range found {
		items[i] = found[i].Item
	}
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next})
}

// hideDistances removes the distance bucket of every member who turned "show my distance" off from a Nearby page.
// The store keeps the bucket in the item (distanceKm) until the page cursor was made, and marks those members.
func hideDistances(items []map[string]any) {
	for _, item := range items {
		if item["distanceHidden"] == true {
			delete(item, "distanceKm")
		}
		delete(item, "distanceHidden")
	}
}

// ---- Photo gallery

type galleryBody struct {
	Photos []domain.ProfilePhoto `json:"photos"`
	Max    int                   `json:"max"`
}

func (a *API) galleryReply(w http.ResponseWriter, r *http.Request, p store.Principal, photos []domain.ProfilePhoto, err error, created bool) {
	if err != nil {
		a.error(w, r, err)
		return
	}
	body := galleryBody{Photos: photos, Max: a.entitlementsFor(r.Context(), p.UserID).ProfilePhotosMax}
	if created {
		a.created(w, r, body, nil)
		return
	}
	a.ok(w, r, body)
}

// listPhotos is GET /v1/me/photos: the caller's gallery in order, and how many photos fit.
func (a *API) listPhotos(w http.ResponseWriter, r *http.Request, p store.Principal) {
	photos, err := a.Store.ProfilePhotos(r.Context(), p.UserID, a.signer(r.Context()))
	a.galleryReply(w, r, p, photos, err, false)
}

// mediaIDBody reads {"mediaId": "<id>"}.
func (a *API) mediaIDBody(w http.ResponseWriter, r *http.Request) (string, bool) {
	raw, ok := a.jsonBody(w, r)
	if !ok {
		return "", false
	}
	var in struct {
		MediaID string `json:"mediaId"`
	}
	if strictDecode(raw, &in) != nil || !domain.IsID(in.MediaID) {
		a.failure(w, r, 422, "VALIDATION", "send mediaId, the id of a photo you uploaded")
		return "", false
	}
	return in.MediaID, true
}

// addPhoto is POST /v1/me/photos {mediaId}: adds an uploaded photo (purpose "avatar", ready, not yet used) at the end.
func (a *API) addPhoto(w http.ResponseWriter, r *http.Request, p store.Principal) {
	id, ok := a.mediaIDBody(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	photos, err := a.Store.AddProfilePhoto(ctx, p.UserID, id, a.entitlementsFor(ctx, p.UserID), a.signer(ctx))
	a.galleryReply(w, r, p, photos, err, true)
}

// replacePhoto is PUT /v1/me/photos/{mediaId} {mediaId}: puts a new photo in the place of this one.
func (a *API) replacePhoto(w http.ResponseWriter, r *http.Request, p store.Principal) {
	id, ok := a.mediaIDBody(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	photos, err := a.Store.ReplaceProfilePhoto(ctx, p.UserID, r.PathValue("mediaId"), id, a.signer(ctx))
	a.galleryReply(w, r, p, photos, err, false)
}

// deletePhoto is DELETE /v1/me/photos/{mediaId}.
func (a *API) deletePhoto(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	photos, err := a.Store.DeleteProfilePhoto(ctx, p.UserID, r.PathValue("mediaId"), a.signer(ctx))
	a.galleryReply(w, r, p, photos, err, false)
}

// reorderPhotos is PUT /v1/me/photos/order {mediaIds: [...]}: every photo of the gallery, once, in the new order.
func (a *API) reorderPhotos(w http.ResponseWriter, r *http.Request, p store.Principal) {
	raw, ok := a.jsonBody(w, r)
	if !ok {
		return
	}
	var in struct {
		MediaIDs []string `json:"mediaIds"`
	}
	if strictDecode(raw, &in) != nil || in.MediaIDs == nil || len(in.MediaIDs) > 64 {
		a.failure(w, r, 422, "VALIDATION", "send mediaIds, your photos in the order you want")
		return
	}
	for _, id := range in.MediaIDs {
		if !domain.IsID(id) {
			a.failure(w, r, 422, "VALIDATION", "send mediaIds, your photos in the order you want")
			return
		}
	}
	ctx := r.Context()
	photos, err := a.Store.ReorderProfilePhotos(ctx, p.UserID, in.MediaIDs, a.signer(ctx))
	a.galleryReply(w, r, p, photos, err, false)
}

// ---- Visitors and places visited

func visitedKey(v store.VisitedPerson) (time.Time, string) { return v.VisitedAt, v.User.UserID }

// recentVisitors is GET /v1/users/{userId}/visitors: who visited that adult's profile in the last 30 days, only when
// they chose to share it and the caller may open the profile. 403 VISITORS_PRIVATE otherwise; a barred member is 404.
func (a *API) recentVisitors(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx, target := r.Context(), r.PathValue("userId")
	if err := a.Store.CanSeeVisitors(ctx, p.UserID, target); err != nil {
		a.error(w, r, err)
		return
	}
	paged(a, w, r, p, "recent_visitors:"+target, func(pg page) ([]store.VisitedPerson, error) {
		return a.Store.ListRecentVisitors(ctx, p.UserID, target, pg.before, pg.id, pg.limit, a.signer(ctx))
	}, visitedKey, nil)
}

// placesVisited is GET /v1/me/visited: the profiles the caller opened in the last 30 days (their own history).
func (a *API) placesVisited(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	paged(a, w, r, p, "places_visited", func(pg page) ([]store.VisitedPerson, error) {
		return a.Store.ListPlacesVisited(ctx, p.UserID, pg.before, pg.id, pg.limit, a.signer(ctx))
	}, visitedKey, nil)
}

// clearPlacesVisited is DELETE /v1/me/visited.
func (a *API) clearPlacesVisited(w http.ResponseWriter, r *http.Request, p store.Principal) {
	n, err := a.Store.ClearPlacesVisited(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	a.ok(w, r, map[string]int64{"cleared": n})
}
