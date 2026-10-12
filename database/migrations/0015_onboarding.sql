-- Server-enforced onboarding. A new account starts incomplete and may only edit
-- its profile and privacy until it declares 18+ and accepts the current terms.
-- The self-declaration is a policy gate, not age assurance: it grants nothing in
-- discovery_eligibility, and the birth date it was computed from is never stored.
CREATE TABLE onboarding (
  user_id uuid PRIMARY KEY REFERENCES users(user_id),
  adult_declared_at timestamptz,
  terms_version text,
  terms_accepted_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- Accounts that exist before this migration keep working: they are complete.
INSERT INTO onboarding(user_id, completed_at, terms_version)
SELECT user_id, now(), 'legacy' FROM users;
