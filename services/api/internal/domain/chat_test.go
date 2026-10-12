package domain

import (
	"reflect"
	"testing"
)

func TestSharedInterests(t *testing.T) {
	cases := []struct {
		name         string
		mine, theirs []string
		want         []string
	}{
		{"nothing", []string{"Music"}, []string{"Art"}, []string{}},
		{"empty sides", nil, []string{"Art"}, []string{}},
		{"case-insensitive, caller's spelling", []string{"Music", "Gaming"}, []string{"gAMING", "music"}, []string{"Music", "Gaming"}},
		{"caller's order", []string{"B", "A", "C"}, []string{"c", "a", "b"}, []string{"B", "A", "C"}},
		{"capped at three", []string{"a", "b", "c", "d"}, []string{"a", "b", "c", "d"}, []string{"a", "b", "c"}},
		{"duplicates", []string{"a", "A", "b"}, []string{"a", "b"}, []string{"a", "b"}},
		{"unicode", []string{"Café ☕"}, []string{"CAFÉ ☕"}, []string{"Café ☕"}},
	}
	for _, tc := range cases {
		if got := SharedInterests(tc.mine, tc.theirs); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: got %#v, want %#v", tc.name, got, tc.want)
		}
	}
}
