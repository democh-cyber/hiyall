-- Indexes behind the account purge, retention jobs and foreign key actions (re-audit DB-6), and the partial index
-- of live sessions. Added while the tables are small; each is a plain CREATE INDEX, which blocks writes to its
-- table for the moments it takes now and would not later (use CONCURRENTLY, in a "-- hiyall:no-transaction"
-- file, for an index added to a big table).
--
-- The privilege side of this release (grants on views, the column grant on content_cases, the split into roles.sql
-- and grants.sql) lives in database/roles, which is not a migration: it is applied by hiyall_migrate after the
-- migrations (cmd/migrate with MIGRATE_RUN_GRANTS=true).

-- Every delete that follows a device (account purge, stale device revocation, ON DELETE CASCADE from devices)
-- finds the device's envelopes through this. envelopes_inbox is partial (undelivered only) and leads with the
-- same column, so it cannot serve delivered rows.
CREATE INDEX IF NOT EXISTS message_envelopes_recipient ON message_envelopes (recipient_device_id);

-- A space's entries: deleting a space, the foreign key check on spaces, the purge of a space's entries. The
-- existing space_entries_list is partial (live entries) and cannot serve soft-deleted ones.
CREATE INDEX IF NOT EXISTS space_entries_space ON space_entries (space_id);

-- friendships has (user_low_id, user_high_id) as its unique key, which serves the low side only. The high side
-- had two partial indexes (accepted, pending); the purge and the user_high_id foreign key check need every row.
CREATE INDEX IF NOT EXISTS friendships_high ON friendships (user_high_id);

-- Live sessions per member: presence, the Nearby online filter and the console's session count only want
-- sessions that are not revoked. Revoked sign-ins from an identity provider are kept, so sessions_user
-- grows with every sign-out while this index stays as small as the live set. last_seen_at is not in it, so the
-- once a minute refresh of a session keeps its HOT update.
CREATE INDEX IF NOT EXISTS sessions_live_user ON sessions (user_id) WHERE revoked_at IS NULL;
