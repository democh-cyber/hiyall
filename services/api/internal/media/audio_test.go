package media

import (
	"encoding/binary"
	"errors"
	"testing"
)

func mkBox(kind string, body ...[]byte) []byte {
	var payload []byte
	for _, b := range body {
		payload = append(payload, b...)
	}
	out := make([]byte, 8, 8+len(payload))
	binary.BigEndian.PutUint32(out, uint32(8+len(payload)))
	copy(out[4:], kind)
	return append(out, payload...)
}

func mvhd(timescale, duration uint32) []byte {
	body := make([]byte, 100)
	binary.BigEndian.PutUint32(body[12:], timescale)
	binary.BigEndian.PutUint32(body[16:], duration)
	return mkBox("mvhd", body)
}

func track(handler string) []byte {
	hdlr := make([]byte, 24)
	copy(hdlr[8:], handler)
	return mkBox("trak", mkBox("mdia", mkBox("hdlr", hdlr)))
}

func clip(brand string, tracks []byte, timescale, duration uint32) []byte {
	ftyp := mkBox("ftyp", []byte(brand), []byte{0, 0, 0, 0}, []byte("isom"))
	return append(append(ftyp, mkBox("moov", mvhd(timescale, duration), tracks)...), mkBox("mdat", make([]byte, 64))...)
}

func TestValidateAudio(t *testing.T) {
	ok := clip("M4A ", track("soun"), 1000, 12500)
	if ms, err := ValidateAudio(ok, 60); err != nil || ms != 12500 {
		t.Fatalf("valid clip: %d %v", ms, err)
	}
	if ms, err := ValidateAudio(clip("isom", track("soun"), 44100, 44100*61), 60); err != nil || ms != 61000 {
		t.Fatalf("61 s is inside the one second of slack: %d %v", ms, err)
	}
	if _, err := ValidateAudio(clip("M4A ", track("soun"), 1000, 62000), 60); !errors.Is(err, ErrAudioTooLong) {
		t.Fatalf("62 s must be too long, got %v", err)
	}
	for name, data := range map[string][]byte{
		"a video track":    clip("isom", append(track("soun"), track("vide")...), 1000, 5000),
		"no audio track":   clip("isom", track("text"), 1000, 5000),
		"an image":         append([]byte{0xff, 0xd8, 0xff, 0xe0}, make([]byte, 64)...),
		"a wrong brand":    clip("qt  ", track("soun"), 1000, 5000),
		"no duration":      clip("M4A ", track("soun"), 1000, 0),
		"a zero timescale": clip("M4A ", track("soun"), 0, 5000),
		"too short":        []byte("ftyp"),
		"a lying box":      append(clip("M4A ", track("soun"), 1000, 5000)[:40], 0xff, 0xff, 0xff, 0xff, 'm', 'o', 'o', 'v', 0, 0, 0, 0),
	} {
		if _, err := ValidateAudio(data, 60); !errors.Is(err, ErrBadAudio) {
			t.Errorf("%s: %v", name, err)
		}
	}
}
