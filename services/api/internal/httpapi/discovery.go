package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"time"

	"github.com/google/uuid"
	"hiyall/services/api/internal/domain"
	"hiyall/services/api/internal/store"
)

func (a *API) allowSearch(id string) bool { return a.search.allow(id) }

type peopleCursor struct {
	User  string `json:"u"`
	Query string `json:"q"`
	After string `json:"a"`
	Exp   int64  `json:"e"`
	Page  int    `json:"p"`
}

func (a *API) peopleSign(c peopleCursor) string { return sealCursor(a, "", c) }

func isUUID(value string) bool {
	_, err := uuid.Parse(value)
	return err == nil
}

func (a *API) searchPeople(w http.ResponseWriter, r *http.Request, p store.Principal) {
	body, err := decode(w, r)
	if err != nil {
		a.error(w, r, err)
		return
	}
	f, err := domain.ParsePeopleFilters(body)
	if err != nil {
		a.error(w, r, err)
		return
	}
	// Every page counts against the day: a script cannot walk the member base with filters and cursors.
	if err = a.Store.BumpDaily(r.Context(), p.UserID, domain.DailySearchPages, a.entitlementsFor(r.Context(), p.UserID).SearchPagesPerDay); err != nil {
		a.error(w, r, err)
		return
	}
	raw := f.Cursor
	f.Cursor = ""
	data, _ := json.Marshal(f)
	sum := sha256.Sum256(data)
	query := hex.EncodeToString(sum[:])
	after := uuid.Nil.String()
	page := 0
	if raw != "" {
		var c peopleCursor
		if !openCursor(a, "", raw, &c) || c.User != p.UserID || c.Query != query || c.Exp <= time.Now().Unix() || c.Page <= 0 || c.Page >= 10 || !isUUID(c.After) {
			a.failure(w, r, 422, "INVALID_CURSOR", "Start a new search")
			return
		}
		after = c.After
		page = c.Page
	}
	items, resume, err := a.Store.SearchPeoplePage(r.Context(), p.UserID, f, after, 21, a.presence, a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	switch {
	case len(items) > 20:
		items = items[:20]
		if page < 9 {
			next = a.peopleSign(peopleCursor{User: p.UserID, Query: query, After: items[19]["userId"].(string), Exp: time.Now().Add(15 * time.Minute).Unix(), Page: page + 1})
		}
	case resume != "" && page < 9:
		// The page was cut by the candidate cap, not by running out of members: carry on after the last one examined
		// (each page still counts against the day and the page limit).
		next = a.peopleSign(peopleCursor{User: p.UserID, Query: query, After: resume, Exp: time.Now().Add(15 * time.Minute).Unix(), Page: page + 1})
	}
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next})
}
