-- Profile photos (avatars).
--
-- An avatar is an ordinary media_assets row (same upload, re-encode and cleanup
-- pipeline as post and story photos) whose purpose is 'avatar'. The profile keeps
-- its id as profiles.data->>'avatarMediaId' (already part of the profile JSON, null
-- until a photo is set); the API attaches the row and releases the previous one in
-- the same transaction as the profile update. Rendering joins media_assets by that
-- id, one primary-key probe per person, so no extra index is needed.
ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_purpose_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_purpose_check CHECK (purpose IN ('post','story','avatar'));
