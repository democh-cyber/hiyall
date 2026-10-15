package config

import (
	"strings"
	"testing"
)

func TestSafetyDefaultsAndRanges(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.MediaProcessSlots != 2 || c.ExportConcurrency != 3 || c.EvidenceRetentionDays != 365 || c.EvidenceSeparate() {
		t.Fatalf("defaults: %+v", c.Safety)
	}
	for name, kv := range map[string][2]string{
		"slots zero":      {"MEDIA_PROCESS_SLOTS", "0"},
		"slots too many":  {"MEDIA_PROCESS_SLOTS", "99"},
		"slots text":      {"MEDIA_PROCESS_SLOTS", "two"},
		"export zero":     {"EXPORT_CONCURRENCY", "0"},
		"retention short": {"EVIDENCE_RETENTION_DAYS", "3"},
		"retention text":  {"EVIDENCE_RETENTION_DAYS", "a year"},
	} {
		t.Run(name, func(t *testing.T) {
			firebaseEnv(t, "hiyall-prod-1")
			t.Setenv(kv[0], kv[1])
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), kv[0]) {
				t.Fatalf("%s=%q: %v", kv[0], kv[1], err)
			}
		})
	}
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("MEDIA_PROCESS_SLOTS", "4")
	t.Setenv("EXPORT_CONCURRENCY", "5")
	t.Setenv("EVIDENCE_RETENTION_DAYS", "730")
	if c, err = Load(); err != nil || c.MediaProcessSlots != 4 || c.ExportConcurrency != 5 || c.EvidenceRetentionDays != 730 {
		t.Fatalf("%+v %v", c.Safety, err)
	}
}

func TestNearbyOffsetKeyIsRequiredInProductionOnly(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("NEARBY_OFFSET_KEY", "")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "NEARBY_OFFSET_KEY") {
		t.Fatalf("production started without the offset key: %v", err)
	}
	t.Setenv("NEARBY_OFFSET_KEY", "short")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "NEARBY_OFFSET_KEY") {
		t.Fatalf("a bad key was accepted: %v", err)
	}
	t.Setenv("NEARBY_OFFSET_KEY", "")
	t.Setenv("NEARBY_OFFSET_KEY_PREVIOUS", testCursorKey)
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "NEARBY_OFFSET_KEY") {
		t.Fatalf("a previous key alone was accepted: %v", err)
	}
	t.Setenv("NEARBY_OFFSET_KEY", testCursorKey)
	if c, err := Load(); err != nil || c.NearbyOffsetKeyPrevious == nil {
		t.Fatalf("%v", err)
	}
	// Development needs none: the store makes a random key per process.
	opsEnv(t, map[string]string{"NEARBY_OFFSET_KEY": "", "NEARBY_OFFSET_KEY_PREVIOUS": "", "FIREBASE_SERVICE_ACCOUNT_FILE": ""})
	if c, err := Load(); err != nil || c.NearbyOffsetKey != nil {
		t.Fatalf("development: %v", err)
	}
}

func TestEvidenceBucketRules(t *testing.T) {
	media := func(t *testing.T) {
		firebaseEnv(t, "hiyall-prod-1")
		t.Setenv("MEDIA_ENDPOINT", "acct.r2.cloudflarestorage.com")
		t.Setenv("MEDIA_ACCESS_KEY", "a")
		t.Setenv("MEDIA_SECRET_KEY", "b")
		t.Setenv("MEDIA_SECURE", "true")
		t.Setenv("MEDIA_BUCKET", "hiyall")
		t.Setenv("SCAN_ALLOW_NONE", "true")
	}
	t.Run("production refuses a shared bucket", func(t *testing.T) {
		media(t)
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "EVIDENCE_BUCKET") {
			t.Fatalf("production started with evidence in the media bucket: %v", err)
		}
	})
	t.Run("shared bucket is allowed on purpose", func(t *testing.T) {
		media(t)
		t.Setenv("EVIDENCE_ALLOW_SHARED_BUCKET", "true")
		if c, err := Load(); err != nil || c.EvidenceSeparate() {
			t.Fatalf("%v", err)
		}
	})
	t.Run("a separate bucket needs its own token", func(t *testing.T) {
		media(t)
		t.Setenv("EVIDENCE_BUCKET", "hiyall-evidence")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "EVIDENCE_ACCESS_KEY") {
			t.Fatalf("no token: %v", err)
		}
		t.Setenv("EVIDENCE_ACCESS_KEY", "w")
		t.Setenv("EVIDENCE_SECRET_KEY", "w")
		c, err := Load()
		if err != nil || !c.EvidenceSeparate() || c.EvidenceEndpoint != "acct.r2.cloudflarestorage.com" || !c.EvidenceSecure || c.EvidenceRegion != c.MediaRegion {
			t.Fatalf("%+v %v", c.Safety, err)
		}
	})
	t.Run("never the media or chat bucket", func(t *testing.T) {
		media(t)
		t.Setenv("EVIDENCE_BUCKET", "hiyall")
		t.Setenv("EVIDENCE_ACCESS_KEY", "w")
		t.Setenv("EVIDENCE_SECRET_KEY", "w")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "social media bucket") {
			t.Fatalf("evidence in the media bucket: %v", err)
		}
	})
	t.Run("credentials without a bucket", func(t *testing.T) {
		media(t)
		t.Setenv("EVIDENCE_ALLOW_SHARED_BUCKET", "true")
		t.Setenv("EVIDENCE_ACCESS_KEY", "w")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "EVIDENCE_BUCKET") {
			t.Fatalf("%v", err)
		}
	})
	t.Run("development keeps it simple", func(t *testing.T) {
		opsEnv(t, map[string]string{"MEDIA_ENDPOINT": "127.0.0.1:9000", "MEDIA_ACCESS_KEY": "a", "MEDIA_SECRET_KEY": "b", "FIREBASE_SERVICE_ACCOUNT_FILE": "", "EVIDENCE_BUCKET": "", "EVIDENCE_ACCESS_KEY": "", "EVIDENCE_SECRET_KEY": "", "EVIDENCE_ALLOW_SHARED_BUCKET": ""})
		if c, err := Load(); err != nil || c.EvidenceSeparate() {
			t.Fatalf("%v", err)
		}
	})
	t.Run("production evidence needs TLS", func(t *testing.T) {
		media(t)
		t.Setenv("EVIDENCE_BUCKET", "hiyall-evidence")
		t.Setenv("EVIDENCE_ACCESS_KEY", "w")
		t.Setenv("EVIDENCE_SECRET_KEY", "w")
		t.Setenv("EVIDENCE_SECURE", "false")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "EVIDENCE_SECURE") {
			t.Fatalf("%v", err)
		}
	})
}

func TestDebugLogPeerParses(t *testing.T) {
	opsEnv(t, map[string]string{"DEBUG_LOG_PEER": "true"})
	if c, err := Load(); err != nil || !c.DebugLogPeer {
		t.Fatalf("%v", err)
	}
	opsEnv(t, map[string]string{"DEBUG_LOG_PEER": "1"})
	if _, err := Load(); err == nil {
		t.Fatal("accepted 1")
	}
}
