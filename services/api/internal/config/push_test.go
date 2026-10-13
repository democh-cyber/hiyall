package config

import "testing"

func TestFCMDefaultsToTheFirebaseProjectAndIsOptional(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "development")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	c, err := Load()
	if err != nil || c.FCMProjectID != "" || c.FCMServiceAccountFile != "" {
		t.Fatalf("unset: %+v %v", c, err)
	}
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("FIREBASE_PROJECT_ID", "hiyall-prod-1")
	t.Setenv("FCM_SERVICE_ACCOUNT_FILE", "/secrets/fcm.json")
	if c, err = Load(); err != nil || c.FCMProjectID != "hiyall-prod-1" || c.FCMServiceAccountFile != "/secrets/fcm.json" {
		t.Fatalf("default project: %+v %v", c, err)
	}
	t.Setenv("FCM_PROJECT_ID", "other-project")
	if c, err = Load(); err != nil || c.FCMProjectID != "other-project" {
		t.Fatalf("explicit project: %+v %v", c, err)
	}
	t.Setenv("FCM_PROJECT_ID", "Bad Project")
	if _, err = Load(); err == nil {
		t.Fatal("invalid FCM_PROJECT_ID accepted")
	}
}
