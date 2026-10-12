package media

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"testing"
	"time"
)

// NoCreate makes no request at all, so a token scoped to one bucket never tries to create it. The
// endpoint here accepts no connection: any bucket call would fail.
func TestNewS3NoCreateTouchesNothing(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cfg := S3Config{Endpoint: "127.0.0.1:1", AccessKey: "id", SecretKey: "secret", Bucket: "hiyall-chat", Region: "auto", NoCreate: true}
	if _, err := NewS3(ctx, cfg); err != nil {
		t.Fatalf("NoCreate reached for the bucket: %v", err)
	}
	cfg.NoCreate = false
	if _, err := NewS3(ctx, cfg); err == nil {
		t.Fatal("the social store no longer checks its bucket")
	}
}

// The checksum helper signs the content type and the SHA-256 header; the old helper signs only the type.
func TestPresignPutChecksumSignsTheChecksumHeader(t *testing.T) {
	ctx := context.Background()
	s3, err := NewS3(ctx, S3Config{Endpoint: "acct.r2.cloudflarestorage.com", AccessKey: "id", SecretKey: "secret", Bucket: "hiyall-chat", Region: "auto", Secure: true, NoCreate: true})
	if err != nil {
		t.Fatal(err)
	}
	const sum = "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	raw, headers, err := s3.PresignPutChecksum(ctx, "chat/abc", "application/octet-stream", sum, 4096, 15*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	signed := strings.Split(u.Query().Get("X-Amz-SignedHeaders"), ";")
	want := map[string]bool{"content-length": false, "content-type": false, "host": false, "x-amz-checksum-sha256": false}
	for _, h := range signed {
		if _, ok := want[h]; !ok {
			t.Fatalf("unexpected signed header %q in %v", h, signed)
		}
		want[h] = true
	}
	for h, ok := range want {
		if !ok {
			t.Fatalf("header %s not signed: %v", h, signed)
		}
	}
	if u.Path != "/hiyall-chat/chat/abc" || u.Query().Get("X-Amz-Expires") != "900" {
		t.Fatalf("url %s", raw)
	}
	if headers.Get("Content-Type") != "application/octet-stream" || headers.Get("x-amz-checksum-sha256") != sum || len(headers) != 2 {
		t.Fatalf("headers %v", headers)
	}
	// The public-media helper signs the content type and the size alone, and lists only the type.
	raw, headers, err = s3.PresignPut(ctx, "media/x", "image/jpeg", 123456, time.Minute)
	if err != nil || strings.Contains(raw, "checksum") {
		t.Fatalf("social presign changed: %s %v", raw, err)
	}
	if u, err = url.Parse(raw); err != nil {
		t.Fatal(err)
	}
	if signed := strings.Split(u.Query().Get("X-Amz-SignedHeaders"), ";"); strings.Join(signed, ";") != "content-length;content-type;host" {
		t.Fatalf("signed headers %v", signed)
	}
	if len(headers) != 1 || headers.Get("Content-Type") != "image/jpeg" {
		t.Fatalf("headers %v", headers)
	}
}

// Content-Length is signed so the store refuses any other body size, but it is never handed to the
// uploader as a header to set: HTTP clients derive it from the body and browsers forbid setting it.
func TestPresignedPutSignsTheDeclaredSizeButDoesNotReturnIt(t *testing.T) {
	ctx := context.Background()
	s3, err := NewS3(ctx, S3Config{Endpoint: "acct.r2.cloudflarestorage.com", AccessKey: "id", SecretKey: "secret", Bucket: "hiyall", Region: "auto", Secure: true, NoCreate: true})
	if err != nil {
		t.Fatal(err)
	}
	signature := func(size int64) string {
		raw, headers, err := s3.PresignPut(ctx, "media/x", "image/jpeg", size, time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := headers["Content-Length"]; ok {
			t.Fatalf("Content-Length returned to the client: %v", headers)
		}
		u, _ := url.Parse(raw)
		if !strings.Contains(u.Query().Get("X-Amz-SignedHeaders"), "content-length") {
			t.Fatalf("content-length not signed: %s", raw)
		}
		return u.Query().Get("X-Amz-Signature")
	}
	// The declared size is part of what is signed: another size is another signature.
	if signature(1000) == signature(1001) {
		t.Fatal("the signature does not depend on the declared size")
	}
}

func TestMemoryStatAndSizes(t *testing.T) {
	ctx := context.Background()
	m := NewMemory()
	if _, err := m.Stat(ctx, "k"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing object: %v", err)
	}
	_ = m.Put(ctx, "k", []byte("12345"), "")
	if size, err := m.Stat(ctx, "k"); err != nil || size != 5 {
		t.Fatalf("stat %d %v", size, err)
	}
	m.Sizes["k"] = 4 << 20
	if size, _ := m.Stat(ctx, "k"); size != 4<<20 {
		t.Fatalf("size override %d", size)
	}
	if !m.Has("k") || len(m.Keys()) != 1 {
		t.Fatal("inspection helpers")
	}
	_ = m.Delete(ctx, "k")
	if m.Has("k") || len(m.Sizes) != 0 {
		t.Fatal("delete kept state")
	}
	if ErrorCode(ErrNotFound) != "NoSuchKey" || ErrorCode(errors.New("https://x?X-Amz-Signature=1")) != "unknown" {
		t.Fatal("ErrorCode leaks or misreports")
	}
}
