package media

import (
	"encoding/binary"
	"errors"
)

// Voice clips (docs/api/27-stories-notices-support.md). A clip is an audio-only MP4 (AAC in an .m4a container,
// content type audio/mp4) of at most 60 seconds. The server validates it and does not transcode or re-encode it:
// there is nothing like EXIF to strip from AAC, and decoding audio on the request path would need a codec the
// API does not carry. Validation reads the container's own boxes, so a file that is not an MP4, has a video track,
// or claims a longer duration than the limit is refused. The upload scanner (images only) does not apply to audio:
// a clip is never rendered as pixels, only played, and the scanner's hash lists and classifiers are image based.

// AudioContentTypes are the voice upload types.
var AudioContentTypes = map[string]bool{"audio/mp4": true}

// MaxAudioBytes is the largest voice upload (4 MiB: about two minutes of AAC at 256 kbit/s, so the 60 second limit
// is what binds, not the size).
const MaxAudioBytes = 4 << 20

// ErrBadAudio is returned for a file that is not an acceptable voice clip.
var ErrBadAudio = errors.New("not a valid voice clip")

var audioBrands = map[string]bool{"M4A ": true, "mp42": true, "isom": true, "iso2": true, "mp41": true, "M4B ": true}

// ValidateAudio checks that data is an audio-only MP4 and returns its duration in milliseconds. maxSeconds is the
// longest allowed clip (a second of slack covers encoder padding).
func ValidateAudio(data []byte, maxSeconds int) (int, error) {
	if len(data) < 32 || len(data) > MaxAudioBytes {
		return 0, ErrBadAudio
	}
	var brandOK bool
	var moov []byte
	for off := 0; off < len(data); {
		size, kind, header, ok := box(data, off)
		if !ok {
			return 0, ErrBadAudio
		}
		body := data[off+header : off+size]
		switch kind {
		case "ftyp":
			brandOK = len(body) >= 8 && audioBrands[string(body[:4])]
		case "moov":
			moov = body
		}
		off += size
	}
	if !brandOK || moov == nil {
		return 0, ErrBadAudio
	}
	durationMs, audio, video, err := readMovie(moov)
	if err != nil || !audio || video || durationMs <= 0 {
		return 0, ErrBadAudio
	}
	if durationMs > (maxSeconds+1)*1000 {
		return durationMs, ErrAudioTooLong
	}
	return durationMs, nil
}

// ErrAudioTooLong is returned with the duration that was read.
var ErrAudioTooLong = errors.New("voice clip is too long")

// box reads the header of the box at off: its total size, its four-character type and the header length.
func box(data []byte, off int) (size int, kind string, header int, ok bool) {
	if off+8 > len(data) {
		return 0, "", 0, false
	}
	size32 := binary.BigEndian.Uint32(data[off:])
	kind = string(data[off+4 : off+8])
	header = 8
	switch size32 {
	case 0:
		size = len(data) - off
	case 1:
		if off+16 > len(data) {
			return 0, "", 0, false
		}
		big := binary.BigEndian.Uint64(data[off+8:])
		if big > uint64(len(data)) {
			return 0, "", 0, false
		}
		size, header = int(big), 16
	default:
		size = int(size32)
	}
	if size < header || off+size > len(data) {
		return 0, "", 0, false
	}
	return size, kind, header, true
}

// readMovie walks a moov body: the movie header's duration and the handler type of every track.
func readMovie(moov []byte) (durationMs int, audio, video bool, err error) {
	for off := 0; off < len(moov); {
		size, kind, header, ok := box(moov, off)
		if !ok {
			return 0, false, false, ErrBadAudio
		}
		body := moov[off+header : off+size]
		switch kind {
		case "mvhd":
			if durationMs, err = movieDuration(body); err != nil {
				return 0, false, false, err
			}
		case "trak":
			a, v := trackKind(body)
			audio, video = audio || a, video || v
		}
		off += size
	}
	return durationMs, audio, video, nil
}

func movieDuration(body []byte) (int, error) {
	if len(body) < 20 {
		return 0, ErrBadAudio
	}
	var timescale uint32
	var duration uint64
	switch body[0] {
	case 0:
		timescale, duration = binary.BigEndian.Uint32(body[12:]), uint64(binary.BigEndian.Uint32(body[16:]))
	case 1:
		if len(body) < 32 {
			return 0, ErrBadAudio
		}
		timescale, duration = binary.BigEndian.Uint32(body[20:]), binary.BigEndian.Uint64(body[24:])
	default:
		return 0, ErrBadAudio
	}
	if timescale == 0 || duration > uint64(timescale)*3600 {
		return 0, ErrBadAudio
	}
	return int(duration * 1000 / uint64(timescale)), nil
}

// trackKind looks for the handler type inside trak > mdia > hdlr.
func trackKind(trak []byte) (audio, video bool) {
	mdia := child(trak, "mdia")
	hdlr := child(mdia, "hdlr")
	if len(hdlr) < 12 {
		return false, false
	}
	switch string(hdlr[8:12]) {
	case "soun":
		return true, false
	case "vide":
		return false, true
	}
	return false, false
}

// child returns the body of the first box of the given type directly inside container.
func child(container []byte, kind string) []byte {
	for off := 0; off < len(container); {
		size, k, header, ok := box(container, off)
		if !ok {
			return nil
		}
		if k == kind {
			return container[off+header : off+size]
		}
		off += size
	}
	return nil
}
