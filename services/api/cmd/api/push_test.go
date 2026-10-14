package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"

	"hiyall/services/api/internal/config"
	"hiyall/services/api/internal/push"
)

// mustSender is pushSender for the cases that may not fail.
func mustSender(t *testing.T, cfg config.Config) push.Sender {
	t.Helper()
	sender, err := pushSender(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return sender
}

func TestPushStaysALoggedNoOpUnlessFCMIsConfigured(t *testing.T) {
	if _, ok := mustSender(t, config.Config{}).(push.LogSender); !ok {
		t.Fatal("unconfigured push is not the log stand-in")
	}
	dir := t.TempDir()
	broken := filepath.Join(dir, "broken.json")
	os.WriteFile(broken, []byte(`{"type":"service_account"`), 0o600)
	for _, file := range []string{filepath.Join(dir, "missing.json"), broken} {
		if _, ok := mustSender(t, config.Config{FCMServiceAccountFile: file}).(push.LogSender); !ok {
			t.Fatalf("%s did not fall back to logging", file)
		}
	}
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	raw, _ := json.Marshal(map[string]string{"type": "service_account", "project_id": "hiyall-prod-1", "client_email": "x@y.iam.gserviceaccount.com",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	good := filepath.Join(dir, "good.json")
	os.WriteFile(good, raw, 0o600)
	sender, ok := mustSender(t, config.Config{FCMServiceAccountFile: good}).(*push.FCM)
	if !ok || sender.ProjectID != "hiyall-prod-1" {
		t.Fatalf("configured push is %T", sender)
	}
	if sender, _ = mustSender(t, config.Config{FCMServiceAccountFile: good, FCMProjectID: "other-1"}).(*push.FCM); sender == nil || sender.ProjectID != "other-1" {
		t.Fatal("FCM_PROJECT_ID not honoured")
	}
}

// In production a set but unusable FCM file stops the start; unset stays a logged no-op.
func TestProductionRefusesABrokenFCMFile(t *testing.T) {
	dir := t.TempDir()
	broken := filepath.Join(dir, "broken.json")
	os.WriteFile(broken, []byte(`{"type":"service_account"`), 0o600)
	for _, file := range []string{filepath.Join(dir, "missing.json"), broken} {
		if _, err := pushSender(config.Config{Env: "production", FCMServiceAccountFile: file}); err == nil {
			t.Fatalf("production started with %s", file)
		}
	}
	if _, err := pushSender(config.Config{Env: "production"}); err != nil {
		t.Fatalf("unset FCM must stay optional: %v", err)
	}
}
