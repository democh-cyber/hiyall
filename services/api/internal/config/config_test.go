package config

import "testing"

func TestProductionFailsClosed(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app?sslmode=disable")
	t.Setenv("APP_ENV", "production")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	if _, err := Load(); err == nil {
		t.Fatal("production accepted development credentials")
	}
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("OIDC_ISSUER", "https://identity.example")
	t.Setenv("OIDC_AUDIENCE", "kairova-api")
	if _, err := Load(); err == nil {
		t.Fatal("production accepted an unverified database connection")
	}
	t.Setenv("DATABASE_URL", "postgresql://db.example/app?sslmode=verify-full")
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
}
func TestDevAuthCannotBindPublicly(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "development")
	t.Setenv("ENABLE_DEV_AUTH", "true")
	t.Setenv("LISTEN_ADDR", "0.0.0.0:8080")
	if _, err := Load(); err == nil {
		t.Fatal("public dev auth")
	}
}

func TestEnvironmentMustBeExplicit(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://localhost/app")
	t.Setenv("APP_ENV", "")
	t.Setenv("ENABLE_DEV_AUTH", "false")
	t.Setenv("OIDC_ISSUER", "http://identity.example")
	t.Setenv("OIDC_AUDIENCE", "kairova-api")
	if _, err := Load(); err == nil {
		t.Fatal("unset APP_ENV skipped production safety checks")
	}
}
