-- Per-member limits on Pulse photos, posts and stories (docs/api/16-pulse-and-media.md#limits-and-quotas).
--
-- The daily limits count rows by creation time over a rolling 24 hours, deleted ones included (deleting
-- never refunds), so the counts must not depend on deleted_at. The existing partial indexes
-- (posts_author, stories_author, media_owner) do not serve them: these two plain indexes do, as one
-- range probe per request. media_assets already has media_owner (owner_id, created_at DESC).
CREATE INDEX IF NOT EXISTS posts_author_created ON posts(author_id,created_at);
CREATE INDEX IF NOT EXISTS stories_author_created ON stories(author_id,created_at);

-- size_bytes changes meaning when a photo is processed: it is the size the member declared while the
-- upload is pending, then the stored size of the re-encoded variants once it is ready (the storage cap
-- sums it). The daily upload bytes limit counts what was declared at slot creation whatever became of
-- the upload, so that number needs its own column. Existing rows get their current size_bytes, which
-- can only undercount the last 24 hours once.
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS declared_bytes bigint;
UPDATE media_assets SET declared_bytes=size_bytes WHERE declared_bytes IS NULL;
ALTER TABLE media_assets ALTER COLUMN declared_bytes SET NOT NULL;
