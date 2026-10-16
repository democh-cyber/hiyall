package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/identity"
)

// serviceAccount writes a syntactically valid service-account key (a throwaway RSA key) and returns its path.
func serviceAccount(t *testing.T, dir, name string) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	raw, _ := json.Marshal(map[string]string{"type": "service_account", "project_id": "hiyall-prod-1", "client_email": "x@y.iam.gserviceaccount.com",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// productionEnv sets a complete production environment (every release requirement met) and returns its directory.
func productionEnv(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, k := range []string{"APPLE_SIGN_IN_ENABLED", "APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_CLIENT_ID", "APPLE_PRIVATE_KEY_FILE",
		"SCAN_PROVIDER_URL", "SCAN_PROVIDER_KEY_FILE", "SCAN_ALLOW_NONE", "APP_CHECK_ENFORCE", "WEB_ORIGIN", "OIDC_ISSUER", "OIDC_AUDIENCE",
		"ENABLE_DEV_AUTH", "CLIENT_IP_HEADER", "AGE_BAND_ISOLATION", "METRICS_ADDR", "FCM_PROJECT_ID", "DIRECT_LISTENER", "DEBUG_LOG_PEER", "EVIDENCE_ALLOW_SHARED_BUCKET", "EVIDENCE_ENDPOINT"} {
		t.Setenv(k, "")
	}
	hash := filepath.Join(dir, "hashes.txt")
	os.WriteFile(hash, []byte(strings.Repeat("a", 64)+"\n"), 0o600)
	for k, v := range map[string]string{
		"APP_ENV": "production", "LISTEN_ADDR": "0.0.0.0:8080",
		"DATABASE_URL":        "postgresql://hiyall:pw@db.internal:5432/hiyall?sslmode=verify-full",
		"FIREBASE_PROJECT_ID": "hiyall-prod-1", "FIREBASE_SERVICE_ACCOUNT_FILE": serviceAccount(t, dir, "fb.json"),
		"FCM_SERVICE_ACCOUNT_FILE": serviceAccount(t, dir, "fcm.json"),
		"CURSOR_KEY":               "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
		"RATE_LIMIT_BACKEND":       "postgres", "BEHIND_PROXY": "true", "TRUSTED_PROXY_CIDRS": "10.0.0.0/8",
		"MEDIA_ENDPOINT": "acct.r2.cloudflarestorage.com", "MEDIA_ACCESS_KEY": "a", "MEDIA_SECRET_KEY": "b", "MEDIA_SECURE": "true", "MEDIA_BUCKET": "hiyall-prod",
		"CHAT_MEDIA_ENDPOINT": "acct.r2.cloudflarestorage.com", "CHAT_MEDIA_ACCESS_KEY": "a", "CHAT_MEDIA_SECRET_KEY": "b", "CHAT_MEDIA_SECURE": "true", "CHAT_MEDIA_BUCKET": "hiyall-chat-prod",
		"NEARBY_OFFSET_KEY": "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=", "EVIDENCE_BUCKET": "hiyall-evidence-prod", "EVIDENCE_ACCESS_KEY": "w", "EVIDENCE_SECRET_KEY": "w",
		"SCAN_HASHLIST_FILE": hash, "SENTRY_DSN": "https://key@o1.ingest.sentry.io/1",
		"MIN_CLIENT_VERSION_ANDROID": "1.0.0", "MIN_CLIENT_VERSION_IOS": "1.0.0",
	} {
		t.Setenv(k, v)
	}
	// APPLE_* is left unset on purpose: a start accepts that, a release does not.
	return dir
}

func runCheck(t *testing.T, args ...string) (int, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := checkConfig(args, &out, &errOut)
	return code, out.String() + errOut.String()
}

func TestCheckConfigReportsWhatAStartWouldRefuse(t *testing.T) {
	productionEnv(t)
	if code, out := runCheck(t); code != 0 || !strings.Contains(out, "config check passed") {
		t.Fatalf("a valid production environment failed: %d %s", code, out)
	}
	t.Setenv("RATE_LIMIT_BACKEND", "memory")
	code, out := runCheck(t)
	if code != 1 || !strings.Contains(out, "RATE_LIMIT_BACKEND=postgres is required") {
		t.Fatalf("the start check must be reported: %d %s", code, out)
	}
}

func TestCheckConfigRejectsAnUnreadableKeyFileLikeAStartDoes(t *testing.T) {
	productionEnv(t)
	t.Setenv("FCM_SERVICE_ACCOUNT_FILE", "/nonexistent/fcm.json")
	if code, out := runCheck(t); code != 1 || !strings.Contains(out, "FCM_SERVICE_ACCOUNT_FILE is set but unusable") {
		t.Fatalf("%d %s", code, out)
	}
}

func TestCheckConfigReleaseListsEveryUnmetRequirement(t *testing.T) {
	productionEnv(t)
	// A start accepts this environment; a release does not (no Apple revocation) and says why.
	code, out := runCheck(t, "-release")
	if code != 1 || !strings.Contains(out, "APPLE_SIGN_IN_ENABLED=true") {
		t.Fatalf("release must demand Apple revocation: %d %s", code, out)
	}
	for _, name := range []string{"SENTRY_DSN", "MIN_CLIENT_VERSION_ANDROID", "MIN_CLIENT_VERSION_IOS", "FCM_SERVICE_ACCOUNT_FILE"} {
		t.Setenv(name, "")
	}
	code, out = runCheck(t, "-release")
	for _, want := range []string{"SENTRY_DSN is required", "MIN_CLIENT_VERSION_ANDROID is required", "MIN_CLIENT_VERSION_IOS is required", "FCM_SERVICE_ACCOUNT_FILE is required", "problem(s)"} {
		if code != 1 || !strings.Contains(out, want) {
			t.Fatalf("missing %q in %d: %s", want, code, out)
		}
	}
	// Without -release the same environment passes.
	if code, out := runCheck(t); code != 0 {
		t.Fatalf("plain check must pass: %d %s", code, out)
	}
}

func TestCheckConfigReleaseRefusesPlaceholdersAndDevelopment(t *testing.T) {
	productionEnv(t)
	t.Setenv("MEDIA_ENDPOINT", "<ACCOUNT_ID>.r2.cloudflarestorage.com")
	if _, out := runCheck(t, "-release"); !strings.Contains(out, "MEDIA_ENDPOINT still contains template placeholder text") {
		t.Fatal(out)
	}
	t.Setenv("MEDIA_ENDPOINT", "acct.r2.cloudflarestorage.com")
	t.Setenv("APP_ENV", "development")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	t.Setenv("DATABASE_URL", "postgresql://hiyall@localhost/hiyall?sslmode=disable")
	if _, out := runCheck(t, "-release"); !strings.Contains(out, "APP_ENV must be production") {
		t.Fatal(out)
	}
}

func TestCheckConfigWarnsAboutUnscannedUploadsAndUsage(t *testing.T) {
	productionEnv(t)
	t.Setenv("SCAN_HASHLIST_FILE", "")
	t.Setenv("SCAN_ALLOW_NONE", "true")
	code, out := runCheck(t)
	if code != 0 || !strings.Contains(out, "warning: SCAN_ALLOW_NONE=true") || !strings.Contains(out, "warning: APP_CHECK_ENFORCE=false") {
		t.Fatalf("%d %s", code, out)
	}
	if code, _ := runCheck(t, "-bogus"); code != 2 {
		t.Fatalf("a bad flag is a usage error, got %d", code)
	}
}

func TestCheckConfigNeverPrintsASecret(t *testing.T) {
	productionEnv(t)
	t.Setenv("DATABASE_URL", "postgresql://hiyall:s3cretpassw0rd@db.internal:5432/hiyall?sslmode=disable")
	if _, out := runCheck(t); strings.Contains(out, "s3cretpassw0rd") {
		t.Fatal("the database password was printed")
	}
}

// How clients arrive and where evidence goes are release decisions (audit API-1, SAFE-1).
func TestReleaseRequiresAClientAddressDecisionAndEvidenceBucket(t *testing.T) {
	productionEnv(t)
	t.Setenv("BEHIND_PROXY", "")
	t.Setenv("TRUSTED_PROXY_CIDRS", "")
	t.Setenv("DIRECT_LISTENER", "")
	if code, out := runCheck(t); code != 1 || !strings.Contains(out, "DIRECT_LISTENER") {
		t.Fatalf("a start must refuse an undecided client address: %d %s", code, out)
	}
	t.Setenv("DIRECT_LISTENER", "true")
	if code, out := runCheck(t); code != 0 {
		t.Fatalf("direct listener refused: %d %s", code, out)
	}
	productionEnv(t)
	t.Setenv("DEBUG_LOG_PEER", "true")
	if _, out := runCheck(t, "-release"); !strings.Contains(out, "DEBUG_LOG_PEER must be unset") {
		t.Fatalf("debug peer logging passed the release check: %s", out)
	}
	productionEnv(t)
	t.Setenv("EVIDENCE_BUCKET", "")
	t.Setenv("EVIDENCE_ACCESS_KEY", "")
	t.Setenv("EVIDENCE_SECRET_KEY", "")
	if code, out := runCheck(t); code != 1 || !strings.Contains(out, "EVIDENCE_BUCKET") {
		t.Fatalf("a start must refuse evidence in the media bucket: %d %s", code, out)
	}
	t.Setenv("EVIDENCE_ALLOW_SHARED_BUCKET", "true")
	if _, out := runCheck(t, "-release"); !strings.Contains(out, "EVIDENCE_BUCKET (and its write-only token) is required") {
		t.Fatalf("a shared evidence bucket passed the release check: %s", out)
	}
}

// appleEnv adds a real (throwaway) Apple key and the four APPLE_* values to productionEnv's environment.
func appleEnv(t *testing.T, dir string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	file := filepath.Join(dir, "AuthKey_ABC123.p8")
	if err = os.WriteFile(file, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]string{"APPLE_SIGN_IN_ENABLED": "true", "APPLE_TEAM_ID": "TEAM123456", "APPLE_KEY_ID": "ABC123", "APPLE_CLIENT_ID": "app.hiyall.test", "APPLE_PRIVATE_KEY_FILE": file} {
		t.Setenv(k, v)
	}
}

// Round-3 audit API-1: -release, -db and -net ask Apple whether the APPLE_* values work.
func TestCheckConfigProbesAppleAndSeparatesBadCredentialsFromNoNetwork(t *testing.T) {
	appleEnv(t, productionEnv(t))
	original := appleProbe
	t.Cleanup(func() { appleProbe = original })
	calls := 0
	answer := func(err error) { appleProbe = func(*identity.AppleRevoker) error { calls++; return err } }

	answer(nil)
	if code, out := runCheck(t, "-release"); code != 0 || calls != 1 {
		t.Fatalf("a configured Apple client: %d calls=%d %s", code, calls, out)
	}
	answer(identity.ErrAppleClientRejected)
	code, out := runCheck(t, "-release")
	if code != 1 || !strings.Contains(out, "problem: Apple rejected APPLE_TEAM_ID") || !strings.Contains(out, "invalid_client") {
		t.Fatalf("invalid_client must fail: %d %s", code, out)
	}
	answer(identity.ErrAppleUnreachable)
	code, out = runCheck(t, "-release")
	if code != 0 || !strings.Contains(out, "warning: could not reach Apple") {
		t.Fatalf("no network is a warning only: %d %s", code, out)
	}
	answer(&identity.AppleError{Status: 400, Code: "unsupported_grant_type"})
	if code, out = runCheck(t, "-release"); code != 0 || !strings.Contains(out, "warning: Apple answered the APPLE_* probe") {
		t.Fatalf("an odd answer is a warning: %d %s", code, out)
	}
	// A plain check never calls Apple; -net does.
	calls = 0
	answer(nil)
	if code, _ = runCheck(t); code != 0 || calls != 0 {
		t.Fatalf("plain check dialled Apple: %d", calls)
	}
	if _, _ = runCheck(t, "-net"); calls != 1 {
		t.Fatalf("-net must probe Apple, calls=%d", calls)
	}
}

// Round-3 audit API-2: -net proves the API's evidence token is write-only, or fails.
func TestCheckConfigNetRunsTheEvidenceCanary(t *testing.T) {
	productionEnv(t)
	original := evidenceProbe
	t.Cleanup(func() { evidenceProbe = original })
	calls := 0
	answer := func(problem, warning string, err error) {
		evidenceProbe = func(config.Config) (string, string, error) { calls++; return problem, warning, err }
	}
	answer("", "", nil)
	if code, out := runCheck(t, "-release"); calls != 0 {
		t.Fatalf("the canary must not run without -net: %d %s", code, out)
	}
	if code, out := runCheck(t, "-net"); code != 0 || calls != 1 {
		t.Fatalf("a write-only token: %d calls=%d %s", code, calls, out)
	}
	answer("the API's evidence token can delete objects in the evidence bucket", "", nil)
	if code, out := runCheck(t, "-net"); code != 1 || !strings.Contains(out, "problem: the API's evidence token can delete") {
		t.Fatalf("a deletable token must fail: %d %s", code, out)
	}
	answer("", "EVIDENCE_ALLOW_API_DELETE=true: accepted with a bucket-lock", nil)
	if code, out := runCheck(t, "-net"); code != 0 || !strings.Contains(out, "warning: EVIDENCE_ALLOW_API_DELETE=true") {
		t.Fatalf("an accepted token: %d %s", code, out)
	}
	answer("", "", errors.New("the evidence token cannot write a probe object (code AccessDenied)"))
	if code, out := runCheck(t, "-net"); code != 0 || !strings.Contains(out, "warning: evidence token canary did not run") {
		t.Fatalf("a probe that could not run: %d %s", code, out)
	}
}
