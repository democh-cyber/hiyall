package config

import (
	"errors"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Safety holds the trust-and-safety settings added after the first audit: the Nearby offset key, photo
// processing and export limits, and the evidence bucket (docs/security/16-csam-and-illegal-content.md,
// docs/security/15-admin-console.md, docs/api/16, docs/deployment/10-deploy-guide.md).
type Safety struct {
	// NearbyOffsetKey (NEARBY_OFFSET_KEY, base64 of 32 bytes) keys the stable per-member offset that is added
	// to a shared point before it is rounded and stored: HMAC(user id, key) gives a fixed direction and
	// distance (up to 2 km, 5 km for minors) for each member, so averaging many days of results does not
	// converge on the true position. Required in production. Changing it moves every member's offset once;
	// never rotate it casually. NearbyOffsetKeyPrevious (NEARBY_OFFSET_KEY_PREVIOUS) is accepted so a rotation
	// can be written down in the environment, but is never used for a lookup: offsets are not looked up, they
	// are recomputed, and a stored point simply refreshes under the new key at the member's next update.
	NearbyOffsetKey, NearbyOffsetKeyPrevious []byte

	// MediaProcessSlots (MEDIA_PROCESS_SLOTS, default 2) is how many photo uploads this node decodes and
	// re-encodes at once; the rest wait, then get 503 with Retry-After. Decode memory is bounded by
	// media.MaxPixels (12 MP) times this.
	MediaProcessSlots int
	// ExportConcurrency (EXPORT_CONCURRENCY, default 3) is how many data exports one node builds at once; a
	// fourth gets 503 with Retry-After and keeps its daily claim.
	ExportConcurrency int

	// Evidence bucket (EVIDENCE_*): quarantined originals are copied into a bucket of their own. The API's
	// token there is WRITE-ONLY (no read, no delete); the console reads with ADMIN_EVIDENCE_* and a separate
	// delete credential held only by the console's purge job removes released holds. Endpoint and secure
	// default to the media bucket's. Without EVIDENCE_BUCKET, evidence sits in the media bucket under hold/,
	// where the API's own token could delete it: production refuses that unless
	// EVIDENCE_ALLOW_SHARED_BUCKET=true.
	EvidenceEndpoint, EvidenceAccessKey, EvidenceSecretKey, EvidenceBucket, EvidenceRegion string
	EvidenceSecure                                                                         bool
	EvidenceAllowSharedBucket                                                              bool
	// EvidenceRetentionDays (EVIDENCE_RETENTION_DAYS, default 365) is how long the evidence of a NEW quarantine
	// case is held (pending counsel's advice). Existing cases keep the hold_until they have. Production
	// refuses fewer than 365: the law this follows asks for at least a year after a report (round-3 API-8).
	EvidenceRetentionDays int
	// EvidenceCanary (EVIDENCE_CANARY=true) runs the evidence-token canary at start: the API puts a probe object
	// into the evidence bucket with its own credential and then tries to read and to delete it. Production
	// refuses to start when either works (the token was meant to be write-only), unless EvidenceAllowAPIDelete.
	// `api check-config -release -net` runs the same probe once.
	EvidenceCanary bool
	// EvidenceAllowAPIDelete (EVIDENCE_ALLOW_API_DELETE=true) accepts that the API's evidence token CAN read or
	// delete (Cloudflare R2 tokens cannot be made write-only), on the condition that a bucket-lock retention rule
	// on the evidence bucket stops a delete from taking effect (docs/deployment/10-deploy-guide.md). It is a
	// statement that the owner has put that rule in place.
	EvidenceAllowAPIDelete bool
	// NearbyAccountsPerAddress (NEARBY_ACCOUNTS_PER_ADDRESS, default 200) is how many different accounts one
	// source address (an IPv6 /64, an IPv4 address) may use Nearby from in a UTC day. A carrier's NAT or a campus
	// shares one address among many people, so it is a ceiling against account farms, not a quota.
	NearbyAccountsPerAddress int
}

// DefaultEvidenceRetentionDays is one year, pending counsel (audit LEGAL-2).
const DefaultEvidenceRetentionDays = 365

// EvidenceSeparate says whether quarantined originals go to a bucket of their own.
func (s Safety) EvidenceSeparate() bool { return s.EvidenceBucket != "" }

func intRange(name string, def, lo, hi int) (int, error) {
	v := os.Getenv(name)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < lo || n > hi {
		return 0, errors.New(name + " must be a number from " + strconv.Itoa(lo) + " to " + strconv.Itoa(hi))
	}
	return n, nil
}

func (c *Config) loadSafety() error {
	s := &c.Safety
	var err error
	if s.NearbyOffsetKey, err = cursorKey("NEARBY_OFFSET_KEY"); err != nil {
		return err
	}
	if s.NearbyOffsetKeyPrevious, err = cursorKey("NEARBY_OFFSET_KEY_PREVIOUS"); err != nil {
		return err
	}
	if s.NearbyOffsetKeyPrevious != nil && s.NearbyOffsetKey == nil {
		return errors.New("NEARBY_OFFSET_KEY_PREVIOUS needs NEARBY_OFFSET_KEY")
	}
	if s.MediaProcessSlots, err = intRange("MEDIA_PROCESS_SLOTS", 2, 1, 16); err != nil {
		return err
	}
	if s.ExportConcurrency, err = intRange("EXPORT_CONCURRENCY", 3, 1, 50); err != nil {
		return err
	}
	if s.EvidenceRetentionDays, err = intRange("EVIDENCE_RETENTION_DAYS", DefaultEvidenceRetentionDays, 30, 3650); err != nil {
		return err
	}
	if s.NearbyAccountsPerAddress, err = intRange("NEARBY_ACCOUNTS_PER_ADDRESS", 200, 1, 1000000); err != nil {
		return err
	}
	if s.EvidenceAllowSharedBucket, err = boolEnv("EVIDENCE_ALLOW_SHARED_BUCKET"); err != nil {
		return err
	}
	if s.EvidenceCanary, err = boolEnv("EVIDENCE_CANARY"); err != nil {
		return err
	}
	if s.EvidenceAllowAPIDelete, err = boolEnv("EVIDENCE_ALLOW_API_DELETE"); err != nil {
		return err
	}
	s.EvidenceEndpoint, s.EvidenceAccessKey, s.EvidenceSecretKey = os.Getenv("EVIDENCE_ENDPOINT"), os.Getenv("EVIDENCE_ACCESS_KEY"), os.Getenv("EVIDENCE_SECRET_KEY")
	s.EvidenceBucket, s.EvidenceRegion = os.Getenv("EVIDENCE_BUCKET"), os.Getenv("EVIDENCE_REGION")
	if s.EvidenceBucket != "" {
		if s.EvidenceEndpoint == "" {
			s.EvidenceEndpoint = c.MediaEndpoint
		}
		if s.EvidenceRegion == "" {
			s.EvidenceRegion = c.MediaRegion
		}
		if v := os.Getenv("EVIDENCE_SECURE"); v == "" {
			s.EvidenceSecure = c.MediaSecure
		} else if s.EvidenceSecure, err = boolEnv("EVIDENCE_SECURE"); err != nil {
			return err
		}
		if s.EvidenceEndpoint == "" {
			return errors.New("EVIDENCE_BUCKET needs EVIDENCE_ENDPOINT (or MEDIA_ENDPOINT)")
		}
		if s.EvidenceAccessKey == "" || s.EvidenceSecretKey == "" {
			return errors.New("EVIDENCE_ACCESS_KEY and EVIDENCE_SECRET_KEY are required with EVIDENCE_BUCKET: a write-only token for the evidence bucket")
		}
		if s.EvidenceEndpoint == c.MediaEndpoint && s.EvidenceBucket == c.MediaBucket {
			return errors.New("EVIDENCE_BUCKET must not be the social media bucket")
		}
		if s.EvidenceEndpoint == c.ChatMediaEndpoint && s.EvidenceBucket == c.ChatMediaBucket {
			return errors.New("EVIDENCE_BUCKET must not be the chat bucket")
		}
		if c.Env == "production" && !s.EvidenceSecure {
			return errors.New("production evidence storage requires EVIDENCE_SECURE=true")
		}
	} else if s.EvidenceAccessKey != "" || s.EvidenceSecretKey != "" || os.Getenv("EVIDENCE_ENDPOINT") != "" {
		return errors.New("EVIDENCE_ENDPOINT, EVIDENCE_ACCESS_KEY and EVIDENCE_SECRET_KEY need EVIDENCE_BUCKET")
	}
	if c.Env == "production" {
		if names := OwnerVariables(os.Environ()); len(names) > 0 {
			// The schema owner's and the console's credentials must never sit in the process that faces the
			// internet: whoever gets code execution there would read them and defeat the least-privilege roles
			// (round-3 audit API-4). The console and migrate binaries read their own settings.
			return errors.New("production API refuses to start with console or migration settings in its environment: " + strings.Join(names, ", ") +
				" belong to the admin and migrate processes only (docs/deployment/10-deploy-guide.md, database roles); remove them from the API's environment")
		}
		if s.EvidenceRetentionDays < 365 {
			return errors.New("EVIDENCE_RETENTION_DAYS must be at least 365 in production: evidence of a report is held for a year")
		}
		if s.NearbyOffsetKey == nil {
			return errors.New("NEARBY_OFFSET_KEY (base64 of 32 random bytes: openssl rand -base64 32) is required in production")
		}
		if c.MediaEndpoint != "" && !s.EvidenceSeparate() && !s.EvidenceAllowSharedBucket {
			return errors.New("production needs EVIDENCE_BUCKET (a separate bucket whose API token can write but not read or delete), or EVIDENCE_ALLOW_SHARED_BUCKET=true to keep quarantined originals in the media bucket where the API's token can delete them")
		}
	}
	return nil
}

// OwnerVariables lists the variables in environ (KEY=value pairs, as os.Environ gives them) that only the admin
// console or the migrate command read: every ADMIN_* and MIGRATE_* name with a value, except the
// ADMIN_TEST_* ones a developer's shell may carry for the test suite. Production refuses to start the API while
// any is present. It returns names only, sorted, never a value.
func OwnerVariables(environ []string) []string {
	var names []string
	for _, kv := range environ {
		name, value, _ := strings.Cut(kv, "=")
		if value == "" || strings.HasPrefix(name, "ADMIN_TEST_") {
			continue
		}
		if strings.HasPrefix(name, "ADMIN_") || strings.HasPrefix(name, "MIGRATE_") {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}
