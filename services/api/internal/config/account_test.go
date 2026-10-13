package config

import "testing"

func TestFirebaseServiceAccountIsOptionalAndNeedsTheProject(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "development")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	if c, err := Load(); err != nil || c.FirebaseServiceAccountFile != "" {
		t.Fatalf("unset: %+v %v", c, err)
	}
	t.Setenv("FIREBASE_SERVICE_ACCOUNT_FILE", "/secrets/firebase-admin.json")
	if _, err := Load(); err == nil {
		t.Fatal("a service account without a project was accepted")
	}
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("FIREBASE_PROJECT_ID", "hiyall-prod-1")
	if c, err := Load(); err != nil || c.FirebaseServiceAccountFile != "/secrets/firebase-admin.json" {
		t.Fatalf("configured: %+v %v", c, err)
	}
}
