package domain

import (
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"testing"
)

// The text rules are checked against vectors shared with the app: the Dart tests in
// apps/mobile/test/chat_text_test.dart read the same file and must agree on `clean` (CleanText or
// CleanLine) and `nfc` (Normalize) for every case. `stripped` is what the app's sanitiser must make
// of the input; only the app checks it. Text is stored as code point lists so no tool can alter it.
//
// To change the cases: edit them below and run `UPDATE_TEXT_VECTORS=1 go test ./internal/domain -run TextVectors`.

type textVector struct {
	Name      string `json:"name"`
	Input     []rune `json:"input"`
	Multiline bool   `json:"multiline"`
	Clean     bool   `json:"clean"`
	NFC       []rune `json:"nfc"`
	Stripped  []rune `json:"stripped,omitempty"`
	// AppKeeps marks text this API rejects but the app deliberately keeps when it cleans received
	// text: the England, Scotland and Wales flags (an emoji tag sequence).
	AppKeeps bool `json:"appKeeps,omitempty"`
}

const textVectorsFile = "testdata/text_vectors.json"

func rs(parts ...any) []rune {
	var out []rune
	for _, p := range parts {
		switch v := p.(type) {
		case string:
			out = append(out, []rune(v)...)
		case rune:
			out = append(out, v)
		case int:
			out = append(out, rune(v))
		}
	}
	return out
}

func handVectors() []textVector {
	zwj, zwnj := rune(0x200D), rune(0x200C)
	family := rs("👨", zwj, "👩", zwj, "👧")
	cases := []struct {
		name     string
		in       []rune
		stripped []rune
	}{
		{"ascii", rs("hello world"), nil},
		{"empty", nil, nil},
		{"newlines and tab", rs("a\nb\tc\r\nd"), nil},
		{"emoji sequence with joiners", family, nil},
		{"emoji with variation selector", rs("❤", 0xFE0F), nil},
		{"flag", rs("🇮🇳"), nil},
		{"persian zwnj", rs("می", zwnj, "خواهم"), nil},
		{"leading joiner", rs(zwj, "a"), rs("a")},
		{"trailing joiner", rs("a", zwj), rs("a")},
		{"doubled joiner", rs("a", zwj, zwj, "b"), rs("ab")},
		{"joiner then zwnj", rs("a", zwj, zwnj, "b"), rs("ab")},
		{"joiner next to a space", rs("a ", zwj, "b"), rs("a b")},
		{"joiner next to a line break", rs("a", zwj, "\nb"), rs("a\nb")},
		{"zero width space", rs("a", 0x200B, "b"), rs("ab")},
		{"word joiner", rs("a", 0x2060, "b"), rs("ab")},
		{"byte order mark", rs(0xFEFF, "a"), rs("a")},
		{"soft hyphen", rs("a", 0xAD, "b"), rs("ab")},
		{"right to left override", rs("a", 0x202E, "gnp.exe"), rs("agnp.exe")},
		{"left to right embedding", rs(0x202A, "a", 0x202C), rs("a")},
		{"isolates", rs(0x2066, "a", 0x2069), rs("a")},
		{"arabic letter mark", rs("a", 0x061C, "b"), rs("ab")},
		{"directional marks", rs("a", 0x200E, 0x200F, "b"), rs("ab")},
		{"tag characters", rs("a", 0xE0041, 0xE007F), rs("a")},
		{"NUL", rs("a", 0, "b"), rs("ab")},
		{"escape", rs("a", 0x1B, "[0m"), rs("a[0m")},
		{"delete", rs("a", 0x7F), rs("a")},
		{"C1 control", rs("a", 0x85, "b"), rs("ab")},
		{"vertical tab", rs("a", 0x0B, "b"), rs("ab")},
		{"private use", rs("a", 0xE000, "b"), rs("ab")},
		{"private use plane 15", rs("a", 0xF0000), rs("a")},
		{"line separator", rs("a", 0x2028, "b"), rs("ab")},
		{"paragraph separator", rs("a", 0x2029, "b"), rs("ab")},
		{"five marks", rs("a", 0x300, 0x301, 0x302, 0x303, 0x304), nil},
		// The first mark composes into "à", so five remain and nothing is cut.
		{"six marks", rs("a", 0x300, 0x301, 0x302, 0x303, 0x304, 0x305), nil},
		{"seven marks", rs("a", 0x300, 0x301, 0x302, 0x303, 0x304, 0x305, 0x306), rs("à", 0x301, 0x302, 0x303, 0x304, 0x305)},
		{"two runs of five", rs("a", 0x300, 0x301, 0x302, 0x303, 0x304, "b", 0x300, 0x301, 0x302, 0x303, 0x304), nil},
		{"zalgo", rs("z", 0x300, 0x301, 0x302, 0x303, 0x304, 0x305, 0x306, 0x307, 0x308, 0x309, 0x30A, 0x30B), rs("z", 0x300, 0x301, 0x302, 0x303, 0x304)},
		{"devanagari conjunct", rs("क्ष"), nil},
		{"arabic with vowel marks", rs("مُحَمَّد"), nil},
		{"decomposed e acute", rs("e", 0x301), nil},
		{"decomposed with trailing text", rs("cafe", 0x301, "!"), nil},
		{"angstrom sign", rs(0x212B), nil},
		{"ohm sign", rs(0x2126), nil},
		{"two marks need reordering", rs("a", 0x323, 0x307), nil},
		{"two marks already ordered", rs("a", 0x307, 0x323), nil},
		{"u diaeresis macron", rs("u", 0x308, 0x304), nil},
		{"hangul jamo", rs(0x1112, 0x1161, 0x11AB), nil},
		{"hangul syllable", rs("한글"), nil},
		{"hangul LV and T", rs(0xD55C, 0x11AB), nil},
		{"ligature stays", rs("ﬁ"), nil},
		{"fullwidth stays", rs("Ａ"), nil},
		{"composition exclusion", rs(0x0958), nil},
		{"mark after zwsp joins after strip", rs("e", 0x200B, 0x301), rs("é")},
		{"emoji skin tone", rs("👍🏽"), nil},
	}
	var out []textVector
	for _, c := range cases {
		stripped := c.stripped
		if stripped == nil {
			stripped = c.in
		}
		out = append(out, textVector{Name: c.name, Input: c.in, Multiline: true, Clean: CleanText(string(c.in)), NFC: []rune(Normalize(string(c.in))), Stripped: stripped})
	}
	for _, c := range []struct {
		name string
		in   []rune
	}{
		{"england flag", rs("🏴", 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F)},
		{"scotland flag in text", rs("a", "🏴", 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F, "b")},
	} {
		out = append(out, textVector{Name: c.name, Input: c.in, Multiline: true, Clean: CleanText(string(c.in)), NFC: []rune(Normalize(string(c.in))), Stripped: c.in, AppKeeps: true})
	}
	// The one-line rules.
	for _, c := range []struct {
		name string
		in   []rune
	}{
		{"line: plain", rs("hello")},
		{"line: newline", rs("a\nb")},
		{"line: tab", rs("a\tb")},
		{"line: carriage return", rs("a\rb")},
	} {
		out = append(out, textVector{Name: c.name, Input: c.in, Multiline: false, Clean: CleanLine(string(c.in)), NFC: []rune(Normalize(string(c.in)))})
	}
	return out
}

// randomVectors covers normalisation broadly: seeded strings drawn from characters that compose,
// decompose and reorder (every Latin and Greek letter with its marks, Hangul, Indic, Arabic, emoji).
func randomVectors() []textVector {
	pool := []rune{'a', 'e', 'o', 'u', 'A', 'E', 'O', 'U', 'c', 'n', 's', 'z', ' ', '\n', 'α', 'ω', 'ι', 'и', 'к', 'ა', 'क', 'ष', 'ا', 'ب', 'ل', '한', 'ᄒ', 'ᅡ', 'ᆫ', '👩', '🏽', '❤'}
	marks := []rune{0x300, 0x301, 0x302, 0x303, 0x304, 0x306, 0x307, 0x308, 0x30A, 0x30B, 0x30C, 0x31B, 0x323, 0x327, 0x328, 0x331, 0x342, 0x345, 0x3099, 0x309A, 0x93C, 0x94D, 0x64B, 0x651, 0xFE0F}
	special := []rune{0x212A, 0x212B, 0x2126, 0x1E9B, 0x0344, 0x0958, 0x0F73, 0x2ADC, 0x1D15E, 0xFB1D, 0x1F71, 0x0340, 0x0341, 0x200D, 0x200C, 0x200B, 0x202E, 0xE000}
	r := rand.New(rand.NewSource(20261014))
	var out []textVector
	for i := 0; i < 400; i++ {
		var in []rune
		for n := 1 + r.Intn(8); n > 0; n-- {
			switch k := r.Intn(10); {
			case k < 4:
				in = append(in, pool[r.Intn(len(pool))])
			case k < 8:
				in = append(in, marks[r.Intn(len(marks))])
			default:
				in = append(in, special[r.Intn(len(special))])
			}
		}
		out = append(out, textVector{Name: "random", Input: in, Multiline: true, Clean: CleanText(string(in)), NFC: []rune(Normalize(string(in)))})
	}
	return out
}

func TestTextVectors(t *testing.T) {
	if os.Getenv("UPDATE_TEXT_VECTORS") == "1" {
		all := append(handVectors(), randomVectors()...)
		// One vector per line keeps the file small and its diffs readable.
		data := []byte("[\n")
		for i, v := range all {
			line, err := json.Marshal(v)
			if err != nil {
				t.Fatal(err)
			}
			data = append(data, line...)
			if i < len(all)-1 {
				data = append(data, ',')
			}
			data = append(data, '\n')
		}
		data = append(data, "]\n"...)
		if err := os.WriteFile(filepath.FromSlash(textVectorsFile), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(filepath.FromSlash(textVectorsFile))
	if err != nil {
		t.Fatal(err)
	}
	var vectors []textVector
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	if len(vectors) < 100 {
		t.Fatalf("only %d vectors", len(vectors))
	}
	for _, v := range vectors {
		in := string(v.Input)
		got := CleanLine(in)
		if v.Multiline {
			got = CleanText(in)
		}
		if got != v.Clean {
			t.Errorf("%s %U: clean = %v, vector says %v", v.Name, v.Input, got, v.Clean)
		}
		if nfc := []rune(Normalize(in)); string(nfc) != string(v.NFC) {
			t.Errorf("%s %U: nfc = %U, vector says %U", v.Name, v.Input, nfc, v.NFC)
		}
		// What the app produces from rejected text must itself be accepted here.
		if len(v.Stripped) > 0 && !v.AppKeeps && !CleanText(string(Normalize(string(v.Stripped)))) {
			t.Errorf("%s: stripped form %U is not clean", v.Name, v.Stripped)
		}
	}
}
