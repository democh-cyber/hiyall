package media

import (
	"bytes"
	"image"
	"image/jpeg"
	"image/png"
	"math/rand"
	"runtime"
	"sync/atomic"
	"testing"
	"time"
)

// peakHeapDuring runs f and returns the highest HeapInuse seen above the starting level, sampled every
// millisecond. It is a lower bound of the true peak (a short spike can fall between samples), so the
// budget below carries headroom, and the numbers in the deploy guide come from this test.
func peakHeapDuring(f func()) uint64 {
	runtime.GC()
	var base runtime.MemStats
	runtime.ReadMemStats(&base)
	var peak atomic.Uint64
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		var m runtime.MemStats
		for {
			select {
			case <-stop:
				return
			default:
			}
			runtime.ReadMemStats(&m)
			if m.HeapInuse > peak.Load() {
				peak.Store(m.HeapInuse)
			}
			time.Sleep(time.Millisecond)
		}
	}()
	f()
	close(stop)
	<-done
	if p := peak.Load(); p > base.HeapInuse {
		return p - base.HeapInuse
	}
	return 0
}

// noise is a worst-case photo for the encoders: nothing compresses, so decode allocates in full.
func noise(w, h int) *image.NRGBA {
	r := rand.New(rand.NewSource(1))
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for i := 0; i < len(img.Pix); i += 4 {
		v := uint8(r.Intn(256))
		img.Pix[i], img.Pix[i+1], img.Pix[i+2], img.Pix[i+3] = v, uint8(i>>8), 255-v, 255
	}
	return img
}

// A 12 MP photo (the MaxPixels limit) is decoded and re-encoded within ProcessHeapBudget, in PNG (the
// widest decode: 4 bytes a pixel) and in JPEG (what phones send). Run with -v to see the numbers.
func TestProcessPeakHeapStaysUnderBudget(t *testing.T) {
	if testing.Short() {
		t.Skip("allocates hundreds of megabytes")
	}
	if raceEnabled {
		t.Skip("the race detector inflates heap figures; the budget is asserted in ordinary builds")
	}
	img := noise(4000, 3000) // exactly MaxPixels
	if img.Bounds().Dx()*img.Bounds().Dy() != MaxPixels {
		t.Fatal("the probe image is not MaxPixels")
	}
	var pngBuf, jpgBuf bytes.Buffer
	if err := png.Encode(&pngBuf, img); err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(&jpgBuf, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	img = nil
	runtime.GC()
	for _, c := range []struct {
		name string
		data []byte
	}{{"png", pngBuf.Bytes()}, {"jpeg", jpgBuf.Bytes()}} {
		var err error
		peak := peakHeapDuring(func() { _, err = Process(c.data) })
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		t.Logf("%s, %d MB upload: peak decode heap %d MB (budget %d MB)", c.name, len(c.data)>>20, peak>>20, ProcessHeapBudget>>20)
		if peak > ProcessHeapBudget {
			t.Errorf("%s: peak heap %d MB is over the %d MB budget", c.name, peak>>20, ProcessHeapBudget>>20)
		}
	}
}

// One pixel over the limit is refused before any pixel is decoded.
func TestProcessRefusesMoreThanMaxPixels(t *testing.T) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewGray(image.Rect(0, 0, 4001, 3000))); err != nil {
		t.Fatal(err)
	}
	peak := peakHeapDuring(func() {
		if _, err := Process(buf.Bytes()); err != ErrUnsupported {
			t.Fatalf("a 12.003 MP image: %v", err)
		}
	})
	if peak > 32<<20 {
		t.Fatalf("a refused image still allocated %d MB", peak>>20)
	}
}

// The blurred preview is small, drops the detail of the original (an edge pattern the original has is gone)
// and refuses what is not an image.
func TestBlurredPreviewHidesDetailAndIsSmall(t *testing.T) {
	// A checkerboard of 8 px squares: maximum high-frequency detail.
	img := image.NewGray(image.Rect(0, 0, 1200, 900))
	for y := 0; y < 900; y++ {
		for x := 0; x < 1200; x++ {
			if (x/8+y/8)%2 == 0 {
				img.Pix[y*img.Stride+x] = 255
			}
		}
	}
	var src bytes.Buffer
	if err := jpeg.Encode(&src, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	out, err := BlurredPreview(src.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	got, err := jpeg.Decode(bytes.NewReader(out))
	if err != nil {
		t.Fatal(err)
	}
	if b := got.Bounds(); b.Dx() > BlurEdge || b.Dy() > BlurEdge || b.Dx() < BlurEdge-2 {
		t.Fatalf("preview is %dx%d", b.Dx(), b.Dy())
	}
	if len(out) > len(src.Bytes())/4 {
		t.Fatalf("preview %d bytes from %d", len(out), len(src.Bytes()))
	}
	// Local contrast: the largest difference between neighbouring pixels. The original is 255; blurred, it is small.
	maxStep := 0
	for y := 0; y < got.Bounds().Dy(); y++ {
		for x := 1; x < got.Bounds().Dx(); x++ {
			a, _, _, _ := got.At(x-1, y).RGBA()
			b, _, _, _ := got.At(x, y).RGBA()
			d := int(a>>8) - int(b>>8)
			if d < 0 {
				d = -d
			}
			maxStep = max(maxStep, d)
		}
	}
	if maxStep > 40 {
		t.Fatalf("the preview keeps detail: adjacent pixels differ by %d of 255", maxStep)
	}
	if _, err = BlurredPreview([]byte("not an image")); err != ErrUnsupported {
		t.Fatalf("garbage: %v", err)
	}
}
