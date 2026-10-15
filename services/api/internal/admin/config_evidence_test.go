package admin

import (
	"encoding/base64"
	"strings"
	"testing"
)

func evidenceEnv(extra map[string]string) func(string) string {
	m := map[string]string{"APP_ENV": "development", "DATABASE_URL": "postgres://x", "ADMIN_DATA_KEY": base64.StdEncoding.EncodeToString(make([]byte, 32))}
	for k, v := range extra {
		m[k] = v
	}
	return func(k string) string { return m[k] }
}

// The evidence bucket has a read-only token for the console and a different delete credential for the purge job.
func TestEvidenceConfigRules(t *testing.T) {
	read := map[string]string{"ADMIN_EVIDENCE_ENDPOINT": "acct.r2.cloudflarestorage.com", "ADMIN_EVIDENCE_ACCESS_KEY": "r", "ADMIN_EVIDENCE_SECRET_KEY": "r", "ADMIN_EVIDENCE_BUCKET": "hiyall-evidence"}
	with := func(extra map[string]string) map[string]string {
		m := map[string]string{}
		for k, v := range read {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	c, err := LoadConfig(evidenceEnv(with(map[string]string{"ADMIN_EVIDENCE_DELETE_ACCESS_KEY": "d", "ADMIN_EVIDENCE_DELETE_SECRET_KEY": "d"})))
	if err != nil || c.EvidenceBucket != "hiyall-evidence" || c.EvidenceDeleteAccessKey != "d" || c.EvidenceAccessKey != "r" {
		t.Fatalf("%+v %v", c, err)
	}
	for name, m := range map[string]map[string]string{
		"endpoint without a token":  {"ADMIN_EVIDENCE_ENDPOINT": "acct.r2.cloudflarestorage.com"},
		"token without an endpoint": {"ADMIN_EVIDENCE_ACCESS_KEY": "r", "ADMIN_EVIDENCE_SECRET_KEY": "r"},
		"half a delete credential":  with(map[string]string{"ADMIN_EVIDENCE_DELETE_ACCESS_KEY": "d"}),
		"the same key to delete":    with(map[string]string{"ADMIN_EVIDENCE_DELETE_ACCESS_KEY": "r", "ADMIN_EVIDENCE_DELETE_SECRET_KEY": "r"}),
		"the media bucket":          with(map[string]string{"ADMIN_MEDIA_ENDPOINT": "acct.r2.cloudflarestorage.com", "ADMIN_MEDIA_ACCESS_KEY": "m", "ADMIN_MEDIA_SECRET_KEY": "m", "ADMIN_MEDIA_BUCKET": "hiyall-evidence"}),
		"bad flag":                  with(map[string]string{"ADMIN_EVIDENCE_SECURE": "yes"}),
	} {
		if _, err := LoadConfig(evidenceEnv(m)); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	// Production: TLS to the evidence bucket; a console with media but no evidence bucket needs the explicit flag.
	prod := map[string]string{"APP_ENV": "production", "DATABASE_URL": "postgres://x?sslmode=verify-full", "ADMIN_DATABASE_URL": "postgres://admin@x?sslmode=verify-full",
		"ADMIN_MEDIA_ENDPOINT": "acct.r2.cloudflarestorage.com", "ADMIN_MEDIA_ACCESS_KEY": "m", "ADMIN_MEDIA_SECRET_KEY": "m", "ADMIN_MEDIA_SECURE": "true"}
	withProd := func(extra map[string]string) map[string]string {
		m := map[string]string{}
		for k, v := range prod {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	if _, err = LoadConfig(evidenceEnv(withProd(nil))); err == nil || !strings.Contains(err.Error(), "ADMIN_EVIDENCE_ENDPOINT") {
		t.Fatalf("production read quarantined photos from the media bucket without saying so: %v", err)
	}
	if _, err = LoadConfig(evidenceEnv(withProd(map[string]string{"EVIDENCE_ALLOW_SHARED_BUCKET": "true"}))); err != nil {
		t.Fatalf("explicit shared bucket: %v", err)
	}
	if _, err = LoadConfig(evidenceEnv(withProd(with(nil)))); err == nil || !strings.Contains(err.Error(), "ADMIN_EVIDENCE_SECURE") {
		t.Fatalf("production evidence without TLS: %v", err)
	}
	if _, err = LoadConfig(evidenceEnv(withProd(with(map[string]string{"ADMIN_EVIDENCE_SECURE": "true"})))); err != nil {
		t.Fatalf("production with an evidence bucket: %v", err)
	}
}

func TestAdminTrustedProxyConfig(t *testing.T) {
	remote := map[string]string{"ADMIN_ADDR": "0.0.0.0:8081", "ADMIN_ALLOW_REMOTE": "true", "ADMIN_TRUST_PROXY": "true", "ADMIN_ALLOWED_HOSTS": "admin.internal"}
	with := func(extra map[string]string) map[string]string {
		m := map[string]string{}
		for k, v := range remote {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	c, err := LoadConfig(evidenceEnv(with(map[string]string{"ADMIN_TRUSTED_PROXY_CIDRS": "10.0.0.0/8, fdaa::/16", "ADMIN_CLIENT_IP_HEADER": "Fly-Client-IP"})))
	if err != nil || len(c.TrustedProxies) != 2 || c.ClientIPHeader != "Fly-Client-IP" {
		t.Fatalf("%+v %v", c, err)
	}
	for name, m := range map[string]map[string]string{
		"bad cidr":            with(map[string]string{"ADMIN_TRUSTED_PROXY_CIDRS": "10.0.0.0/40"}),
		"header without cidr": with(map[string]string{"ADMIN_CLIENT_IP_HEADER": "Fly-Client-IP"}),
	} {
		if _, err := LoadConfig(evidenceEnv(m)); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	// Development tolerates a trusted proxy without CIDRs (the peer is then the client); production does not.
	if _, err = LoadConfig(evidenceEnv(with(nil))); err != nil {
		t.Fatalf("development: %v", err)
	}
	prod := with(map[string]string{"APP_ENV": "production", "DATABASE_URL": "postgres://x?sslmode=verify-full", "ADMIN_DATABASE_URL": "postgres://admin@x?sslmode=verify-full"})
	if _, err = LoadConfig(evidenceEnv(prod)); err == nil || !strings.Contains(err.Error(), "ADMIN_TRUSTED_PROXY_CIDRS") {
		t.Fatalf("production behind a proxy without its address: %v", err)
	}
	prod["ADMIN_TRUSTED_PROXY_CIDRS"] = "10.0.0.0/8"
	if _, err = LoadConfig(evidenceEnv(prod)); err != nil {
		t.Fatalf("production with the proxy's address: %v", err)
	}
}
