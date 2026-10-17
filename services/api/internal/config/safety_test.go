package config

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"hiyall/services/api/internal/domain"
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

// Round-3 audit API-4: the schema owner's and the console's credentials never sit in the API's environment.
func TestProductionRefusesConsoleAndMigrationSettingsInTheAPIEnvironment(t *testing.T) {
	for _, name := range []string{"MIGRATE_DATABASE_URL", "ADMIN_DATABASE_URL", "ADMIN_EVIDENCE_DELETE_SECRET_KEY", "ADMIN_DATA_KEY", "MIGRATE_RUN_GRANTS", "ADMIN_EVIDENCE_ACCESS_KEY"} {
		t.Run(name, func(t *testing.T) {
			firebaseEnv(t, "hiyall-prod-1")
			t.Setenv(name, "x-secret-value-1234")
			_, err := Load()
			if err == nil || !strings.Contains(err.Error(), name) {
				t.Fatalf("production started with %s in the environment: %v", name, err)
			}
			if strings.Contains(err.Error(), "x-secret-value-1234") {
				t.Fatalf("the refusal printed a value: %v", err)
			}
			// Development (and a test shell) may carry them: the console and migrate read their own.
			t.Setenv("APP_ENV", "development")
			t.Setenv("DATABASE_URL", "postgresql://db.example/app?sslmode=disable")
			if _, err = Load(); err != nil && strings.Contains(err.Error(), name) {
				t.Fatalf("development refused %s: %v", name, err)
			}
		})
	}
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("ADMIN_TEST_DATABASE_URL", "postgresql://x/hiyall_test_admin")
	if _, err := Load(); err != nil {
		t.Fatalf("the test-suite variable must not block a start: %v", err)
	}
	if got := OwnerVariables([]string{"ADMIN_DATA_KEY=1", "MIGRATE_DEADLINE=2", "ADMIN_TLS_KEY=", "ADMIN_TEST_C=3", "DATABASE_URL=z", "MY_ADMIN_D=4"}); strings.Join(got, ",") != "ADMIN_DATA_KEY,MIGRATE_DEADLINE" {
		t.Fatalf("OwnerVariables: %v", got)
	}
}

// Round-4 N-10: the refusal matches an explicit list of names, not a prefix, so the variables a platform adds to every
// container (Kubernetes service links for a service called "admin" or "migrate") do not stop a production API.
func TestOwnerVariablesAreAnExplicitListNotAPrefix(t *testing.T) {
	platform := []string{"ADMIN_SERVICE_HOST=10.0.0.7", "ADMIN_SERVICE_PORT=8081", "ADMIN_PORT=tcp://10.0.0.7:8081", "ADMIN_PORT_8081_TCP=tcp://10.0.0.7:8081",
		"ADMIN_PORT_8081_TCP_ADDR=10.0.0.7", "MIGRATE_SERVICE_HOST=10.0.0.8", "MIGRATE_PORT=tcp://10.0.0.8:80", "ADMIN_CONSOLE_URL=https://x", "ADMIN_EVIDENCE_NOTE=x"}
	if got := OwnerVariables(platform); len(got) != 0 {
		t.Fatalf("platform variables counted as owner settings: %v", got)
	}
	firebaseEnv(t, "hiyall-prod-1")
	for _, kv := range platform {
		name, value, _ := strings.Cut(kv, "=")
		t.Setenv(name, value)
	}
	if _, err := Load(); err != nil {
		t.Fatalf("a production API refused to start for service-link variables: %v", err)
	}
	// Every real name is still refused, one at a time.
	for _, name := range OwnerVariableNames() {
		if got := OwnerVariables([]string{name + "=v"}); len(got) != 1 || got[0] != name {
			t.Errorf("%s is not refused: %v", name, got)
		}
	}
	if got := OwnerVariableNames(); len(got) < 30 {
		t.Fatalf("the list looks wrong: %v", got)
	}
}

// The list is complete: every ADMIN_* and MIGRATE_* name the console and the migrate command read is on it, so adding a
// setting to either cannot silently leave the API accepting it.
func TestOwnerVariablesCoverTheConsoleAndMigrateSettings(t *testing.T) {
	listed := map[string]bool{}
	for _, n := range OwnerVariableNames() {
		listed[n] = true
	}
	name := regexp.MustCompile(`"((?:ADMIN|MIGRATE)_[A-Z0-9_]*[A-Z0-9])"`)
	read := 0
	for _, dir := range []string{"../admin", "../../cmd/admin", "../../cmd/migrate"} {
		files, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil || len(files) == 0 {
			t.Fatalf("no sources in %s: %v", dir, err)
		}
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") {
				continue
			}
			src, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			for _, m := range name.FindAllStringSubmatch(string(src), -1) {
				read++
				if !listed[m[1]] {
					t.Errorf("%s reads %s, which is not in ownerVariableNames: a production API would accept it", f, m[1])
				}
			}
		}
	}
	if read < 25 {
		t.Fatalf("only %d names found: the scan is broken", read)
	}
}

// The API's example environment must not carry live console or migrate settings: copied into an API's environment they
// would stop a production start (round-4 N-10).
func TestAPIExampleEnvironmentsHaveNoLiveOwnerVariables(t *testing.T) {
	for _, rel := range []string{"infrastructure/docker/api.example.env", "config/api.production.example.env", "config/api.staging.example.env"} {
		raw, err := os.ReadFile(filepath.Join("../../../..", rel))
		if err != nil {
			t.Fatal(err)
		}
		var live []string
		for _, line := range strings.Split(string(raw), "\n") {
			if trimmed := strings.TrimSpace(line); trimmed != "" && !strings.HasPrefix(trimmed, "#") {
				live = append(live, trimmed)
			}
		}
		if got := OwnerVariables(live); len(got) != 0 {
			t.Errorf("%s has live owner settings (comment them out): %v", rel, got)
		}
		// The same lines with a value would be caught: an empty `NAME=` is not a setting, `NAME=x` is.
		for _, name := range OwnerVariableNames() {
			for _, line := range live {
				if strings.HasPrefix(line, name+"=") && strings.TrimPrefix(line, name+"=") != "" {
					t.Errorf("%s sets %s", rel, name)
				}
			}
		}
	}
}

// Round-3 audit API-8: evidence is held for at least a year in production.
func TestProductionRefusesAnEvidenceRetentionUnderAYear(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	t.Setenv("EVIDENCE_RETENTION_DAYS", "364")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "EVIDENCE_RETENTION_DAYS") {
		t.Fatalf("a 364 day retention started in production: %v", err)
	}
	t.Setenv("EVIDENCE_RETENTION_DAYS", "365")
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
	// Development may use a short one to test the purge.
	t.Setenv("EVIDENCE_RETENTION_DAYS", "30")
	t.Setenv("APP_ENV", "development")
	t.Setenv("DATABASE_URL", "postgresql://db.example/app?sslmode=disable")
	if c, err := Load(); err != nil || c.EvidenceRetentionDays != 30 {
		t.Fatalf("development: %v", err)
	}
}

func TestEvidenceCanaryAndNearbyAddressSettings(t *testing.T) {
	firebaseEnv(t, "hiyall-prod-1")
	c, err := Load()
	// 500 by default (round-4 N-9: 200 was too low behind a carrier's NAT), and the domain's fallback is the same number.
	if err != nil || c.EvidenceCanary || c.EvidenceAllowAPIDelete || c.EvidenceCanaryAcceptUnlocked || c.NearbyAccountsPerAddress != 500 || DefaultNearbyAccountsPerAddress != domain.DefaultNearbyAccountsPerAddress {
		t.Fatalf("defaults: %+v %v", c.Safety, err)
	}
	t.Setenv("EVIDENCE_CANARY", "true")
	t.Setenv("EVIDENCE_ALLOW_API_DELETE", "true")
	t.Setenv("EVIDENCE_CANARY_ACCEPT_UNLOCKED", "true")
	t.Setenv("NEARBY_ACCOUNTS_PER_ADDRESS", "900")
	if c, err = Load(); err != nil || !c.EvidenceCanary || !c.EvidenceAllowAPIDelete || !c.EvidenceCanaryAcceptUnlocked || c.NearbyAccountsPerAddress != 900 {
		t.Fatalf("%+v %v", c.Safety, err)
	}
	for _, kv := range [][2]string{{"EVIDENCE_CANARY", "yes"}, {"EVIDENCE_ALLOW_API_DELETE", "1"}, {"EVIDENCE_CANARY_ACCEPT_UNLOCKED", "on"}, {"NEARBY_ACCOUNTS_PER_ADDRESS", "0"}, {"NEARBY_ACCOUNTS_PER_ADDRESS", "many"}} {
		firebaseEnv(t, "hiyall-prod-1")
		t.Setenv(kv[0], kv[1])
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), kv[0]) {
			t.Fatalf("%s=%s: %v", kv[0], kv[1], err)
		}
	}
}
