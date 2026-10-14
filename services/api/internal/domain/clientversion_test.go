package domain

import "testing"

func TestClientVersion(t *testing.T) {
	ok := map[string][3]int{"1.4.0": {1, 4, 0}, "v2": {2, 0, 0}, "1.4": {1, 4, 0}, "1.4.0-beta.2+77": {1, 4, 0}, " 0.9.12 ": {0, 9, 12}}
	for in, want := range ok {
		if got, valid := ParseClientVersion(in); !valid || got != want {
			t.Errorf("%q -> %v %v", in, got, valid)
		}
	}
	for _, bad := range []string{"", "x", "1.2.3.4", "1..2", "01.2", "-1.0", "1.a", "latest"} {
		if _, valid := ParseClientVersion(bad); valid {
			t.Errorf("%q accepted", bad)
		}
	}
	a, _ := ParseClientVersion("1.4.9")
	b, _ := ParseClientVersion("1.10.0")
	if !ClientVersionLess(a, b) || ClientVersionLess(b, a) || ClientVersionLess(a, a) {
		t.Fatal("ordering")
	}
}
