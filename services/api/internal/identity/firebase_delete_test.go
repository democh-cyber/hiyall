package identity

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// serviceAccount writes a service-account key file whose token endpoint is tokenURI.
func serviceAccount(t *testing.T, tokenURI string) (string, *rsa.PrivateKey) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	file := filepath.Join(t.TempDir(), "sa.json")
	data, _ := json.Marshal(map[string]string{"type": "service_account", "client_email": "svc@test-project.iam.gserviceaccount.com", "token_uri": tokenURI,
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	if err = os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return file, key
}

func TestFirebaseDeleterSignsAssertionAndDeletesTheUser(t *testing.T) {
	var tokens, deletes atomic.Int32
	var key *rsa.PrivateKey
	var gotUID string
	result := http.StatusOK
	message := ""
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		tokens.Add(1)
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
			t.Errorf("grant %q", r.Form.Get("grant_type"))
		}
		parts := strings.Split(r.Form.Get("assertion"), ".")
		if len(parts) != 3 {
			t.Fatalf("assertion %q", r.Form.Get("assertion"))
		}
		sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], sig) != nil { // crypto.SHA256
			t.Error("assertion is not signed by the service account key")
		}
		claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
		if !strings.Contains(string(claims), "svc@test-project.iam.gserviceaccount.com") {
			t.Errorf("claims %s", claims)
		}
		_, _ = w.Write([]byte(`{"access_token":"ya29.test","expires_in":3600}`))
	})
	mux.HandleFunc("/v1/projects/test-project/accounts:delete", func(w http.ResponseWriter, r *http.Request) {
		deletes.Add(1)
		if r.Header.Get("Authorization") != "Bearer ya29.test" {
			t.Errorf("authorization %q", r.Header.Get("Authorization"))
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotUID = body["localId"]
		w.WriteHeader(result)
		_, _ = w.Write([]byte(`{"error":{"message":"` + message + `"}}`))
	})
	server := httptest.NewServer(mux)
	defer server.Close()
	file, k := serviceAccount(t, server.URL+"/token")
	key = k
	d, err := NewFirebaseDeleter("test-project", file)
	if err != nil {
		t.Fatal(err)
	}
	d.apiBase = server.URL + "/v1/projects/"
	issuer := FirebaseIssuer("test-project")
	ctx := context.Background()

	if err = d.DeleteIdentity(ctx, issuer, "uid-1"); err != nil || gotUID != "uid-1" {
		t.Fatalf("delete: %v (uid %q)", err, gotUID)
	}
	// The access token is reused.
	if err = d.DeleteIdentity(ctx, issuer, "uid-2"); err != nil || tokens.Load() != 1 {
		t.Fatalf("second delete: %v, %d token requests", err, tokens.Load())
	}
	// A user that is already gone counts as deleted (the purge retries safely).
	result, message = http.StatusBadRequest, "USER_NOT_FOUND"
	if err = d.DeleteIdentity(ctx, issuer, "uid-3"); err != nil {
		t.Fatalf("already deleted: %v", err)
	}
	// Anything else is an error, which does not repeat the subject.
	result, message = http.StatusForbidden, "PERMISSION_DENIED"
	if err = d.DeleteIdentity(ctx, issuer, "uid-4"); err == nil || strings.Contains(err.Error(), "uid-4") {
		t.Fatalf("refusal: %v", err)
	}
	// Another provider's identity is not ours to delete.
	before := deletes.Load()
	if err = d.DeleteIdentity(ctx, "https://accounts.example.com", "x"); err != nil || deletes.Load() != before {
		t.Fatalf("foreign identity: %v", err)
	}
}

func TestFirebaseDeleterRejectsBrokenKeyFilesAndLogDeleterIsANoOp(t *testing.T) {
	if _, err := NewFirebaseDeleter("test-project", filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("a missing file was accepted")
	}
	for name, content := range map[string]string{"not json": "nope", "no key": `{"client_email":"a@b"}`, "bad pem": `{"client_email":"a@b","private_key":"x"}`} {
		file := filepath.Join(t.TempDir(), "bad.json")
		_ = os.WriteFile(file, []byte(content), 0o600)
		if _, err := NewFirebaseDeleter("test-project", file); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	if err := (LogDeleter{}).DeleteIdentity(context.Background(), "i", "s"); err != nil {
		t.Fatal(err)
	}
}
