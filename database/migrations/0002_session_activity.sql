ALTER TABLE sessions ADD COLUMN last_seen_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE sessions ADD COLUMN platform text NOT NULL DEFAULT 'unknown'
    CHECK (platform IN ('android','ios','web','unknown'));
