package httpapi

import (
	"net/http"
	"strings"

	"hiyall/services/api/internal/domain"
)

// Client contract (audit O6). Apps send X-Client-Platform (android, ios or web) and X-Client-Version (a
// semantic version such as 1.4.0) on every request. When the operator sets a minimum for a platform
// (MIN_CLIENT_VERSION_ANDROID, _IOS, _WEB), a request from that platform with an older version, or with no
// readable version, is answered 426 with code UPGRADE_REQUIRED in the standard error envelope, so a broken
// build can be retired. A request that names no known platform is never refused: nothing says which minimum
// applies. Health probes, the legal documents, development login and sign-out are exempt, so an old client
// can still end its session.
const (
	clientVersionHeader  = "X-Client-Version"
	clientPlatformHeader = "X-Client-Platform"
)

// SetMinClientVersions installs the minimum version per platform; an empty value, or a platform left out,
// switches that platform's check off. Versions are read with domain.ParseClientVersion; an unreadable one is
// ignored (config validates them at startup).
func (a *API) SetMinClientVersions(min map[string]string) {
	a.minClient = map[string][3]int{}
	for platform, value := range min {
		if v, ok := domain.ParseClientVersion(value); ok && strings.TrimSpace(value) != "" {
			a.minClient[strings.ToLower(platform)] = v
		}
	}
}

func upgradeExempt(path string) bool {
	switch path {
	case "/healthz", "/readyz", "/health/live", "/health/ready", "/dev/session", "/v1/auth/logout":
		return true
	}
	return strings.HasPrefix(path, "/v1/legal") || strings.HasPrefix(path, "/legal")
}

// upgradeRequired reports whether r comes from a client older than the configured minimum.
func (a *API) upgradeRequired(r *http.Request) bool {
	if len(a.minClient) == 0 || upgradeExempt(r.URL.Path) {
		return false
	}
	min, ok := a.minClient[strings.ToLower(strings.TrimSpace(r.Header.Get(clientPlatformHeader)))]
	if !ok {
		return false
	}
	have, ok := domain.ParseClientVersion(r.Header.Get(clientVersionHeader))
	return !ok || domain.ClientVersionLess(have, min)
}
