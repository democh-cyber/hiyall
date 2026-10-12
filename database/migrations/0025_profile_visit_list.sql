-- The owner's visitor list (GET /v1/me/visitors, docs/api/13-social-and-activity.md#visitors) reads a
-- profile's visits newest first and stops after the member's VisitorListLimit rows. This index serves
-- that as one ordered range scan, so a very busy profile never sorts all its visits per request.
CREATE INDEX IF NOT EXISTS profile_visits_recent ON profile_visits(profile_id,first_visited_at DESC,visitor_id DESC);
