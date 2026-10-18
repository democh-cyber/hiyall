package httpapi

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"slices"
	"strconv"
	"time"

	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

// presence reports whether a member has a live realtime connection on this node: the hub half of
// presence. The store adds the session-activity half and applies the member's audience (see
// Store.presenceFor), so this answers only for members the viewer may be told about. A node without a
// hub reports nobody connected, and the hub is per node: a member connected to another node still shows
// as online while their sessions are active (within domain.PresenceOnlineWindow of the last request).
func (a *API) presence(userID string) bool { return a.RT != nil && a.RT.Connected(userID) }

// The location and Nearby endpoints (location, nearbySwitch and nearby below) wait for onboarding like every
// route outside the exemption list.
//
//	GET    /v1/me/nearby                    -> {visible, sharing, updatedAt|null}
//	PUT    /v1/me/nearby                    "Show me in Nearby": visible:true (no body); stores no location
//	DELETE /v1/me/nearby                    switch off: visible:false and the stored point is deleted
//	GET    /v1/me/location                  -> {sharing, updatedAt|null}
//	PUT    /v1/me/location                  {latitude, longitude} -> {sharing:true, updatedAt}; 409 NEARBY_OFF unless visible
//	DELETE /v1/me/location                  -> {sharing:false}
//	POST   /v1/discover/nearby              {radiusKm?, interests?, languages?, country?, vibe?, cursor?} -> {items, nextCursor};
//	                                        radiusKm is one of 5, 10, 15, 25, 50, 100; only visible members may ask
func (a *API) location(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	switch r.Method {
	case "GET":
		sharing, updated, err := a.Store.LocationSharing(ctx, p.UserID)
		if err != nil {
			a.error(w, r, err)
			return
		}
		a.ok(w, r, locationBody(sharing, updated))
	case "PUT":
		body, err := decode(w, r)
		var loc domain.LocationInput
		if err == nil {
			// ParseLocation returns the point already rounded, at both the adult and the minor
			// precision; nothing below sees the precise value, and the store picks by age band.
			loc, err = domain.ParseLocation(body)
		}
		if err != nil {
			a.error(w, r, err)
			return
		}
		if !a.locations.allow(p.UserID) {
			w.Header().Set("Retry-After", "120")
			a.failure(w, r, 429, "RATE_LIMITED", "You can update your location again in a couple of minutes")
			return
		}
		updated, err := a.Store.SetLocation(ctx, p.UserID, loc, a.entitlementsFor(ctx, p.UserID))
		if err != nil {
			a.error(w, r, err)
			return
		}
		a.ok(w, r, locationBody(true, &updated))
	case "DELETE":
		if err := a.Store.StopSharingLocation(ctx, p.UserID); err != nil {
			a.error(w, r, err)
			return
		}
		a.ok(w, r, map[string]bool{"sharing": false})
	default:
		a.failure(w, r, 405, "METHOD_NOT_ALLOWED", "Method unavailable")
	}
}

// nearbySwitch is the "Show me in Nearby" setting. Switching it on stores nothing about where the member is;
// switching it off deletes the stored point at once.
func (a *API) nearbySwitch(w http.ResponseWriter, r *http.Request, p store.Principal) {
	ctx := r.Context()
	switch r.Method {
	case "GET":
	case "PUT", "DELETE":
		if !a.locations.allow(p.UserID) {
			w.Header().Set("Retry-After", "120")
			a.failure(w, r, 429, "RATE_LIMITED", "Try again in a couple of minutes")
			return
		}
		if err := a.Store.SetNearbyVisible(ctx, p.UserID, r.Method == "PUT"); err != nil {
			a.error(w, r, err)
			return
		}
	default:
		a.failure(w, r, 405, "METHOD_NOT_ALLOWED", "Method unavailable")
		return
	}
	st, err := a.Store.GetNearby(ctx, p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	body := locationBody(st.Sharing, st.UpdatedAt)
	body["visible"] = st.Visible
	body["minor"] = st.Minor
	a.ok(w, r, body)
}

// locationBody never carries coordinates. updatedAt is null unless sharing.
func locationBody(sharing bool, updated *time.Time) map[string]any {
	var at any
	if sharing && updated != nil {
		at = updated.UTC()
	}
	return map[string]any{"sharing": sharing, "updatedAt": at}
}

// nearbyCursor is signed, not secret. It holds the last bucket and user id of a
// page, never an exact distance or a coordinate: Loc is a keyed hash that ties
// the cursor to the caller's stored point, so moving invalidates it, and Query
// is a hash of the filters (as in people search), so changing a filter or the
// radius does too.
type nearbyCursor struct {
	User   string `json:"u"`
	Radius int    `json:"r"`
	Query  string `json:"q"`
	Loc    string `json:"l"`
	Bucket int    `json:"b"`
	After  string `json:"a"`
	Exp    int64  `json:"e"`
	Page   int    `json:"p"`
}

const nearbyCursorPrefix = "nearby\x00"

func (a *API) nearbySeal(c nearbyCursor) string { return sealCursor(a, nearbyCursorPrefix, c) }

// nearbyCentreTag is a keyed hash of the caller's stored point. It reveals nothing
// about the point and changes when the caller shares a different one.
func (a *API) nearbyCentreTag(loc domain.Location) string {
	mac := hmac.New(sha256.New, a.cursorKey[:])
	mac.Write([]byte("nearby-centre\x00" + strconv.FormatFloat(loc.Latitude, 'f', domain.LocationDecimals, 64) + "," + strconv.FormatFloat(loc.Longitude, 'f', domain.LocationDecimals, 64)))
	return hex.EncodeToString(mac.Sum(nil)[:8])
}

// nearbyQueryHash identifies a filter set. The cursor is cleared first, so the
// hash is the same on every page of one search.
func nearbyQueryHash(f domain.PeopleFilters) string {
	f.Cursor = ""
	data, _ := json.Marshal(f)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// nearbyOpen verifies a cursor for this principal, radius, filters and centre.
func (a *API) nearbyOpen(raw string, principal string, radius int, query, centre string, minorViewer bool) (nearbyCursor, bool) {
	var c nearbyCursor
	if !openCursor(a, nearbyCursorPrefix, raw, &c) {
		return c, false
	}
	return c, isUUID(c.After) && c.User == principal && c.Radius == radius && c.Query == query && c.Loc == centre && c.Exp > time.Now().Unix() && c.Page > 0 && c.Page < 10 && slices.Contains(domain.NearbyBucketsFor(minorViewer), c.Bucket)
}

func (a *API) nearby(w http.ResponseWriter, r *http.Request, p store.Principal) {
	body, err := decode(w, r)
	var req domain.NearbyRequest
	if err == nil {
		req, err = domain.ParseNearbyRequest(body)
	}
	if err != nil {
		a.error(w, r, err)
		return
	}
	// Nearby filters, and the gender filter wherever it is used, are Premium features while plans are enforced (billing.go).
	if !a.nearbyFiltersAllowed(w, r, p, req.Filters) {
		return
	}
	centre, minor, err := a.Store.OwnLocation(r.Context(), p.UserID)
	if err != nil {
		a.error(w, r, err)
		return
	}
	// A minor's radius is widened to the next of their own buckets, so what they ask and what is searched agree.
	req.RadiusKm = domain.NearbyRadiusFor(minor, req.RadiusKm)
	if err = a.Store.BumpDaily(r.Context(), p.UserID, domain.DailyNearbyQueries, a.entitlementsFor(r.Context(), p.UserID).NearbyQueriesPerDay); err != nil {
		a.error(w, r, err)
		return
	}
	tag, query := a.nearbyCentreTag(centre), nearbyQueryHash(req.Filters)
	// How many different centres this account has searched from today, and how many different accounts this
	// source address (an IPv6 /64) has searched for: the stored point is the centre, so moving it around a member
	// is the way to triangulate them (audit API-4), and an address that drives many accounts is a farm (round-3
	// API-3). A centre or an account already counted today is free, so ordinary use is never counted twice.
	if err = a.Store.CountNearbyProbe(r.Context(), p.UserID, a.clientBucket(r), tag, domain.NearbyCentresPerAccount, a.nearbyAccountsPerAddress()); err != nil {
		a.error(w, r, err)
		return
	}
	after := store.NearbyAfter{}
	page := 0
	if req.Filters.Cursor != "" {
		c, ok := a.nearbyOpen(req.Filters.Cursor, p.UserID, req.RadiusKm, query, tag, minor)
		if !ok {
			a.failure(w, r, 422, "INVALID_CURSOR", "Reload people nearby")
			return
		}
		after, page = store.NearbyAfter{Bucket: c.Bucket, UserID: c.After}, c.Page
	}
	items, err := a.Store.NearbyPeople(r.Context(), p.UserID, centre, minor, req.RadiusKm, req.Filters, after, 21, a.presence, a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if len(items) > 20 {
		items = items[:20]
		if page < 9 {
			last := items[19]
			next = a.nearbySeal(nearbyCursor{User: p.UserID, Radius: req.RadiusKm, Query: query, Loc: tag, Bucket: last["distanceKm"].(int), After: last["userId"].(string), Exp: time.Now().Add(15 * time.Minute).Unix(), Page: page + 1})
		}
	}
	hideDistances(items)
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next})
}

// profileViewAllowed counts one profile view of another member's profile against the viewer's day
// (Entitlements.ProfileViewsPerDay) and answers 429 DAILY_LIMIT when it is used up, so a script cannot read
// the member base profile by profile. Opening one's own profile is free.
func (a *API) profileViewAllowed(w http.ResponseWriter, r *http.Request, p store.Principal, target string) bool {
	if target == p.UserID {
		return true
	}
	if err := a.Store.BumpDaily(r.Context(), p.UserID, domain.DailyProfileViews, a.entitlementsFor(r.Context(), p.UserID).ProfileViewsPerDay); err != nil {
		a.error(w, r, err)
		return false
	}
	return true
}
