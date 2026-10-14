package store

import (
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"hiyall/services/api/internal/domain"
)

// A unique violation is "username taken" only for the username's own constraint (audit S8); any other
// duplicate is a conflict, never a claim that a name is taken.
func TestUniqueViolationsAreMappedByConstraintName(t *testing.T) {
	dup := func(constraint string) error {
		return &pgconn.PgError{Code: "23505", ConstraintName: constraint}
	}
	if err := mapped(dup("profiles_username_key")); !errors.Is(err, domain.ErrUsernameTaken) {
		t.Fatalf("username constraint: %v", err)
	}
	for _, other := range []string{"friendships_pkey", "follows_pkey", "devices_identity_key_key", ""} {
		if err := mapped(dup(other)); !errors.Is(err, domain.ErrConflict) || errors.Is(err, domain.ErrUsernameTaken) {
			t.Fatalf("constraint %q: %v", other, err)
		}
	}
}
