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
	// MaxPixels bounds decode memory: a small file can declare a huge canvas.
	MaxPixels = 40_000_000
	FullEdge  = 2048
	ThumbEdge = 640
)

var ErrUnsupported = errors.New("unsupported image")

// Store is the object storage the API needs. Production points it at S3 (or
// any S3-compatible store) behind a CDN; development uses SeaweedFS.
type Store interface {
	// PresignPut lets a client upload one object directly, with the content
	// type fixed by the signature.
	PresignPut(ctx context.Context, key, contentType string, ttl time.Duration) (string, http.Header, error)
	PresignGet(ctx context.Context, key string, ttl time.Duration) (string, error)
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
}

// NewS3 connects and makes sure the bucket exists.
func NewS3(ctx context.Context, c S3Config) (*S3, error) {
	client, err := minio.New(c.Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(c.AccessKey, c.SecretKey, ""),
		Secure: c.Secure,
		Region: c.Region,
	})
	if err != nil {
		return nil, err
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

func (s *S3) PresignPut(ctx context.Context, key, contentType string, ttl time.Duration) (string, http.Header, error) {
	headers := http.Header{"Content-Type": {contentType}}
	u, err := s.client.PresignHeader(ctx, http.MethodPut, s.bucket, key, ttl, url.Values{}, headers)
	if err != nil {
		return "", nil, err
	}
	return u.String(), headers, nil
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

// Memory is an in-process Store for tests.
type Memory struct {
	mu      sync.Mutex
	Objects map[string][]byte
}

func NewMemory() *Memory { return &Memory{Objects: map[string][]byte{}} }

func (m *Memory) PresignPut(_ context.Context, key, contentType string, _ time.Duration) (string, http.Header, error) {
	return "memory://put/" + key, http.Header{"Content-Type": {contentType}}, nil
}
func (m *Memory) PresignGet(_ context.Context, key string, _ time.Duration) (string, error) {
	return "memory://get/" + key, nil
}
func (m *Memory) Get(_ context.Context, key string, limit int64) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	data, ok := m.Objects[key]
	if !ok {
		return nil, errors.New("no such object")
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
	return nil
}
func (m *Memory) Delete(_ context.Context, keys ...string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, k := range keys {
		delete(m.Objects, k)
	}
	return nil
}
