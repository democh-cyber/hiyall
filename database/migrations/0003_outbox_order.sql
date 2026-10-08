ALTER TABLE users ADD COLUMN aggregate_version bigint NOT NULL DEFAULT 0 CHECK (aggregate_version >= 0);
