// Package media stores photo bytes in S3-compatible object storage and turns
// uploads into safe, metadata-free variants. The database only holds keys.
package media

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png" // decoders for accepted uploads
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/disintegration/imaging"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	_ "golang.org/x/image/webp"
)

// Accepted upload types. Video needs a transcoding worker and is not accepted yet.
var ContentTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true}

const (
	MaxUploadBytes = 15 << 20
	// MaxPixels bounds decode memory: a small file can declare a huge canvas. 12 MP covers every phone
	// camera's default photo (12 MP, 4000x3000); a 20 MP PNG measured about 178 MB of heap per decode
	// (audit API-5), so with the process slots (MEDIA_PROCESS_SLOTS, default 2) the worst case is bounded by
	// ProcessHeapBudget below. TestProcessPeakHeapStaysUnderBudget asserts it.
	MaxPixels = 12_000_000
	// ProcessHeapBudget is the most extra heap one Process call may hold at its peak for a MaxPixels image
	// (measured with runtime.MemStats; see the test and docs/deployment/10-deploy-guide.md). The deploy
	// guide's memory table is slots x this, plus the baseline.
	ProcessHeapBudget = 160 << 20
	FullEdge          = 2048
	ThumbEdge         = 640
)

var ErrUnsupported = errors.New("unsupported image")

// ErrNotFound is what Stat and Get answer for a key that holds no object.
var ErrNotFound = errors.New("no such object")

// Store is the object storage the API needs. Production points it at S3 (or
// any S3-compatible store) behind a CDN; development uses SeaweedFS.
type Store interface {
	// PresignPut lets a client upload one object directly. The signature fixes the content type and the
	// exact body size (a Content-Length of size), so the store refuses a larger or a smaller body: the
	// quotas count the declared size, which the upload must therefore be.
	// The returned headers are what the uploader must send; Content-Length is signed but not listed,
	// because HTTP clients set it from the body and browsers forbid setting it.
	PresignPut(ctx context.Context, key, contentType string, size int64, ttl time.Duration) (string, http.Header, error)
	// PresignPutChecksum is PresignPut for ciphertext: the signature also fixes the body's SHA-256
	// (standard base64, as in the x-amz-checksum-sha256 header), so the store refuses any other body.
	PresignPutChecksum(ctx context.Context, key, contentType, sha256B64 string, size int64, ttl time.Duration) (string, http.Header, error)
	PresignGet(ctx context.Context, key string, ttl time.Duration) (string, error)
	// Stat returns the stored size of an object, or ErrNotFound.
	Stat(ctx context.Context, key string) (int64, error)
	// Get reads at most limit bytes; a larger object is an error.
	Get(ctx context.Context, key string, limit int64) ([]byte, error)
	Put(ctx context.Context, key string, data []byte, contentType string) error
	Delete(ctx context.Context, keys ...string) error
}

type S3 struct {
	client *minio.Client
	bucket string
}

type S3Config struct {
	Endpoint, AccessKey, SecretKey, Bucket, Region string
	Secure                                         bool
	// NoCreate skips the bucket check and never creates the bucket, for a token scoped to one
	// existing bucket (the chat bucket). The social store leaves it false and creates its bucket.
	NoCreate bool
}

// NewS3 connects and, unless NoCreate is set, makes sure the bucket exists.
func NewS3(ctx context.Context, c S3Config) (*S3, error) {
	client, err := minio.New(c.Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(c.AccessKey, c.SecretKey, ""),
		Secure: c.Secure,
		Region: c.Region,
	})
	if err != nil {
		return nil, err
	}
	if c.NoCreate {
		return &S3{client: client, bucket: c.Bucket}, nil
	}
	exists, err := client.BucketExists(ctx, c.Bucket)
	if err == nil && !exists {
		err = client.MakeBucket(ctx, c.Bucket, minio.MakeBucketOptions{Region: c.Region})
	}
	if err != nil {
		return nil, fmt.Errorf("media bucket: %w", err)
	}
	return &S3{client: client, bucket: c.Bucket}, nil
}

func (s *S3) PresignPut(ctx context.Context, key, contentType string, size int64, ttl time.Duration) (string, http.Header, error) {
	headers := http.Header{"Content-Type": {contentType}}
	u, err := s.presign(ctx, key, headers, size, ttl)
	return u, headers, err
}

func (s *S3) PresignPutChecksum(ctx context.Context, key, contentType, sha256B64 string, size int64, ttl time.Duration) (string, http.Header, error) {
	headers := http.Header{}
	headers.Set("Content-Type", contentType)
	headers.Set("X-Amz-Checksum-Sha256", sha256B64)
	u, err := s.presign(ctx, key, headers, size, ttl)
	return u, headers, err
}

// presign signs headers plus Content-Length: size, which minio-go adds to the signed headers; the
// store then answers 403 SignatureDoesNotMatch to any other body length. headers is not changed.
func (s *S3) presign(ctx context.Context, key string, headers http.Header, size int64, ttl time.Duration) (string, error) {
	signed := headers.Clone()
	signed.Set("Content-Length", strconv.FormatInt(size, 10))
	u, err := s.client.PresignHeader(ctx, http.MethodPut, s.bucket, key, ttl, url.Values{}, signed)
	if err != nil {
		return "", err
	}
	return u.String(), nil
}

func (s *S3) Stat(ctx context.Context, key string) (int64, error) {
	info, err := s.client.StatObject(ctx, s.bucket, key, minio.StatObjectOptions{})
	if err != nil {
		if resp := minio.ToErrorResponse(err); resp.Code == "NoSuchKey" || (resp.StatusCode == http.StatusNotFound && resp.Code != "NoSuchBucket") {
			return 0, ErrNotFound
		}
		return 0, err
	}
	return info.Size, nil
}

// ErrorCode is the storage service's error code (such as AccessDenied) for logging: unlike the error
// text it can never carry a URL or a credential.
func ErrorCode(err error) string {
	if errors.Is(err, ErrNotFound) {
		return "NoSuchKey"
	}
	if code := minio.ToErrorResponse(err).Code; code != "" {
		return code
	}
	return "unknown"
}

func (s *S3) PresignGet(ctx context.Context, key string, ttl time.Duration) (string, error) {
	u, err := s.client.PresignedGetObject(ctx, s.bucket, key, ttl, url.Values{})
	if err != nil {
		return "", err
	}
	return u.String(), nil
}

func (s *S3) Get(ctx context.Context, key string, limit int64) ([]byte, error) {
	object, err := s.client.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, err
	}
	defer object.Close()
	data, err := io.ReadAll(io.LimitReader(object, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("object larger than %d bytes", limit)
	}
	return data, nil
}

func (s *S3) Put(ctx context.Context, key string, data []byte, contentType string) error {
	_, err := s.client.PutObject(ctx, s.bucket, key, bytes.NewReader(data), int64(len(data)), minio.PutObjectOptions{
		ContentType: contentType,
		// Variant keys never change content, so clients and CDNs may cache them.
		CacheControl: "private, max-age=31536000, immutable",
	})
	return err
}

// List returns at most limit objects under prefix.
func (s *S3) List(ctx context.Context, prefix string, limit int) ([]ObjectInfo, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var out []ObjectInfo
	for o := range s.client.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if o.Err != nil {
			return nil, o.Err
		}
		out = append(out, ObjectInfo{Key: o.Key, LastModified: o.LastModified})
		if len(out) >= limit {
			break
		}
	}
	return out, nil
}

func (s *S3) Delete(ctx context.Context, keys ...string) error {
	for _, key := range keys {
		if err := s.client.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{}); err != nil {
			return err
		}
	}
	return nil
}

// Processed is an upload turned into display variants.
type Processed struct {
	Full, Thumb   []byte
	Width, Height int
}

// Process decodes an uploaded photo, applies its EXIF orientation, and
// re-encodes a full-size and a thumbnail JPEG. Re-encoding from pixels drops
// all metadata, including GPS location.
func Process(data []byte) (Processed, error) {
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "jpeg" && format != "png" && format != "webp") {
		return Processed{}, ErrUnsupported
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width*config.Height > MaxPixels {
		return Processed{}, ErrUnsupported
	}
	img, err := imaging.Decode(bytes.NewReader(data), imaging.AutoOrientation(true))
	if err != nil {
		return Processed{}, ErrUnsupported
	}
	encode := func(edge int) ([]byte, image.Rectangle, error) {
		out := img
		if b := img.Bounds(); b.Dx() > edge || b.Dy() > edge {
			out = imaging.Fit(img, edge, edge, imaging.Lanczos)
		}
		var buf bytes.Buffer
		// Flatten any transparency onto white before JPEG encoding.
		flat := imaging.New(out.Bounds().Dx(), out.Bounds().Dy(), image.White)
		flat = imaging.Overlay(flat, out, image.Pt(0, 0), 1)
		err := jpeg.Encode(&buf, flat, &jpeg.Options{Quality: 82})
		return buf.Bytes(), flat.Bounds(), err
	}
	full, bounds, err := encode(FullEdge)
	if err != nil {
		return Processed{}, err
	}
	thumb, _, err := encode(ThumbEdge)
	if err != nil {
		return Processed{}, err
	}
	return Processed{Full: full, Thumb: thumb, Width: bounds.Dx(), Height: bounds.Dy()}, nil
}

// Memory is an in-process Store for tests. Objects can be read and written directly, and Sizes
// overrides what Stat reports, so a test can claim a large upload without allocating it. Signed
// records the body size each presigned PUT pinned, by key.
type Memory struct {
	mu      sync.Mutex
	Objects map[string][]byte
	// Modified overrides the modification time List reports for a key (Put records the time of the call).
	Modified map[string]time.Time
	Sizes    map[string]int64
	Signed   map[string]int64
}

func NewMemory() *Memory {
	return &Memory{Objects: map[string][]byte{}, Modified: map[string]time.Time{}, Sizes: map[string]int64{}, Signed: map[string]int64{}}
}

func (m *Memory) sign(key string, size int64) {
	m.mu.Lock()
	m.Signed[key] = size
	m.mu.Unlock()
}

func (m *Memory) PresignPut(_ context.Context, key, contentType string, size int64, _ time.Duration) (string, http.Header, error) {
	m.sign(key, size)
	return "memory://put/" + key, http.Header{"Content-Type": {contentType}}, nil
}
func (m *Memory) PresignPutChecksum(_ context.Context, key, contentType, sha256B64 string, size int64, _ time.Duration) (string, http.Header, error) {
	m.sign(key, size)
	headers := http.Header{}
	headers.Set("Content-Type", contentType)
	headers.Set("X-Amz-Checksum-Sha256", sha256B64)
	return "memory://put/" + key, headers, nil
}
func (m *Memory) PresignGet(_ context.Context, key string, _ time.Duration) (string, error) {
	return "memory://get/" + key, nil
}
func (m *Memory) Stat(_ context.Context, key string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	data, ok := m.Objects[key]
	if !ok {
		return 0, ErrNotFound
	}
	if size, ok := m.Sizes[key]; ok {
		return size, nil
	}
	return int64(len(data)), nil
}
func (m *Memory) Get(_ context.Context, key string, limit int64) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	data, ok := m.Objects[key]
	if !ok {
		return nil, ErrNotFound
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("object larger than %d bytes", limit)
	}
	return data, nil
}
func (m *Memory) Put(_ context.Context, key string, data []byte, _ string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.Objects[key] = data
	if m.Modified == nil {
		m.Modified = map[string]time.Time{}
	}
	m.Modified[key] = time.Now()
	return nil
}

// List reports the stored keys under prefix, in key order.
func (m *Memory) List(_ context.Context, prefix string, limit int) ([]ObjectInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []ObjectInfo
	for k := range m.Objects {
		if strings.HasPrefix(k, prefix) {
			out = append(out, ObjectInfo{Key: k, LastModified: m.Modified[k]})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
func (m *Memory) Delete(_ context.Context, keys ...string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, k := range keys {
		delete(m.Objects, k)
		delete(m.Sizes, k)
		delete(m.Modified, k)
	}
	return nil
}

// Has reports whether an object exists.
func (m *Memory) Has(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.Objects[key]
	return ok
}

// Keys lists the stored object keys.
func (m *Memory) Keys() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	keys := make([]string, 0, len(m.Objects))
	for k := range m.Objects {
		keys = append(keys, k)
	}
	return keys
}

// Blur preview of a quarantined photo (docs/security/16-csam-and-illegal-content.md). The console proxies THIS
// by default, never the original: the picture is shrunk to BlurEdge on its long side and blurred hard, in the
// server, so the browser never holds the unblurred pixels unless an administrator takes the audited reveal
// step. A CSS filter would leave the original in the page.
const (
	// BlurEdge is the long side of the preview, in pixels.
	BlurEdge = 240
	// BlurSigma is the Gaussian blur radius applied after the shrink: strong enough that faces, text and
	// the shape of a body are gone, while a person can still tell a photo of a room from a screenshot.
	BlurSigma = 9.0
)

// BlurredPreview returns a small, heavily blurred JPEG of data (the processed copy of a quarantined upload,
// which is at most FullEdge on a side). Metadata is dropped like in Process.
func BlurredPreview(data []byte) ([]byte, error) {
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "jpeg" && format != "png" && format != "webp") || config.Width <= 0 || config.Height <= 0 || config.Width*config.Height > MaxPixels {
		return nil, ErrUnsupported
	}
	img, err := imaging.Decode(bytes.NewReader(data), imaging.AutoOrientation(true))
	if err != nil {
		return nil, ErrUnsupported
	}
	small := imaging.Fit(img, BlurEdge, BlurEdge, imaging.Box)
	blurred := imaging.Blur(small, BlurSigma)
	var buf bytes.Buffer
	if err = jpeg.Encode(&buf, blurred, &jpeg.Options{Quality: 55}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
