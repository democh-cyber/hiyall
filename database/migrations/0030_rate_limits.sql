-- Shared rate limits (RATE_LIMIT_BACKEND=postgres): one token bucket per (limiter, key), so N API nodes
-- enforce one limit instead of N. See services/api/internal/ratelimit.
--
-- The bucket holds `tokens` as of `updated_at` (both set by the database clock, so node clock skew does
-- not matter); a request refills it from the elapsed time, takes one token if there is one, and writes
-- the result back in a single INSERT ... ON CONFLICT DO UPDATE, which PostgreSQL serialises per row.
-- `full_at` is when the bucket would be full again: past that it holds no information and the hourly
-- maintenance job deletes it. `allowed` is the outcome of the last request, returned by the same
-- statement so that a refusal does not cost a second round trip.
--
-- UNLOGGED: no WAL, much cheaper to write, emptied after a crash. A crash then resets every bucket to
-- full, which is harmless for an abuse limit. The table is not replicated; a promoted replica starts
-- empty for the same reason. No index besides the key, and a low fillfactor, so the constant updates
-- stay HOT. With the default backend (memory) this table is simply unused.
CREATE UNLOGGED TABLE IF NOT EXISTS rate_limits (
  bucket text PRIMARY KEY CHECK (length(bucket) BETWEEN 1 AND 200),
  tokens double precision NOT NULL,
  updated_at timestamptz NOT NULL,
  full_at timestamptz NOT NULL,
  allowed boolean NOT NULL DEFAULT true
) WITH (fillfactor = 50);
