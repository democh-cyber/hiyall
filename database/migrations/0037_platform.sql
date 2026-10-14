-- Platform hardening (audit S8, D5).
--
-- S8: a rename starts a 30 day cooldown; the API (store.updateProfile) reads and writes this column.
-- Nullable and unset for everyone today, so no member is locked out by the release.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS username_changed_at timestamptz;

-- D5: the API no longer writes outbox_events or bumps users.aggregate_version, and nothing ever read them.
-- Both stay for one more release (expand, then contract: the release before this one still writes them
-- during a rolling deploy), and the hourly "outbox purge" job removes rows older than 7 days. A later
-- migration drops the table and the column.
