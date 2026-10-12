package httpapi

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
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

func (a *API) peopleSign(c peopleCursor) string {
	data, _ := json.Marshal(c)
	mac := hmac.New(sha256.New, a.cursorKey[:])
	mac.Write(data)
	return base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
func (a *API) searchPeople(w http.ResponseWriter, r *http.Request, p store.Principal) {
	if !a.allowSearch(p.UserID) {
		w.Header().Set("Retry-After", "2")
		a.failure(w, r, 429, "RATE_LIMITED", "Try again shortly")
		return
	}
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
	raw := f.Cursor
	f.Cursor = ""
	data, _ := json.Marshal(f)
	sum := sha256.Sum256(data)
	query := hex.EncodeToString(sum[:])
	after := uuid.Nil.String()
	page := 0
	if raw != "" {
		parts := strings.Split(raw, ".")
		valid := len(parts) == 2
		var c peopleCursor
		if valid {
			bytes, e := base64.RawURLEncoding.DecodeString(parts[0])
			sig, e2 := base64.RawURLEncoding.DecodeString(parts[1])
			mac := hmac.New(sha256.New, a.cursorKey[:])
			mac.Write(bytes)
			valid = e == nil && e2 == nil && hmac.Equal(sig, mac.Sum(nil)) && json.Unmarshal(bytes, &c) == nil && c.User == p.UserID && c.Query == query && c.Exp > time.Now().Unix() && c.Page > 0 && c.Page < 10
			_, e = uuid.Parse(c.After)
			valid = valid && e == nil
		}
		if !valid {
			a.failure(w, r, 422, "INVALID_CURSOR", "Start a new search")
			return
		}
		after = c.After
		page = c.Page
	}
	items, err := a.Store.SearchPeople(r.Context(), p.UserID, f, after, 21, a.presence, a.signer(r.Context()))
	if err != nil {
		a.error(w, r, err)
		return
	}
	var next any
	if len(items) > 20 {
		items = items[:20]
		if page < 9 {
			next = a.peopleSign(peopleCursor{User: p.UserID, Query: query, After: items[19]["userId"].(string), Exp: time.Now().Add(15 * time.Minute).Unix(), Page: page + 1})
		}
	}
	a.ok(w, r, map[string]any{"items": items, "nextCursor": next})
}
