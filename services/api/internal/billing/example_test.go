package billing

import (
	"reflect"
	"testing"
)

// config/billing-catalog.example.json is what the owner copies: it must load and say what the built-in default says.
func TestExampleCatalogLoadsAndMatchesTheDefault(t *testing.T) {
	c, err := LoadCatalog("../../../../config/billing-catalog.example.json")
	if err != nil {
		t.Fatal(err)
	}
	if want := DefaultCatalog(); !reflect.DeepEqual(c, want) {
		t.Fatalf("the example differs from the default:\n%+v\n%+v", c, want)
	}
}
