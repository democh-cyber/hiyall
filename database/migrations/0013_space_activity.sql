ALTER TABLE notifications DROP CONSTRAINT notifications_event_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_event_check CHECK(event IN ('follow.started','follow.requested','follow.accepted','friend.requested','friend.accepted','post.reacted','post.commented','space.invited','space.requested','space.approved'));
