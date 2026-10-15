-- Demo activity from other people for one member, written the way the API writes it (rows, counters and
-- notifications), so the Activity tab, Visitors, Followers, Friends and Pulse numbers all agree.
-- Local development database only. Safe to re-run. Driven by scripts/dev/seed-demo-activity.sh (-v target=<username>).
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF current_database() <> 'hiyall' THEN
    RAISE EXCEPTION 'demo activity is for the local hiyall development database only';
  END IF;
END $$;

CREATE TEMP TABLE t AS SELECT user_id FROM profiles WHERE username = :'target';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM t) THEN
    RAISE EXCEPTION 'no member with that username';
  END IF;
  IF member_age((SELECT user_id FROM t)) < 18 THEN
    RAISE EXCEPTION 'the demo people are adults and cannot interact with a member under 18; pick an adult';
  END IF;
END $$;

-- Only active adults take part, so the age-band rule never hides anyone from the target.
CREATE TEMP TABLE actors AS
SELECT p.username, p.user_id, p.data->>'displayName' AS name
  FROM profiles p JOIN users u USING (user_id)
 WHERE u.status = 'active' AND p.username LIKE 'demo\_%' AND member_age(p.user_id) >= 18
   AND p.username NOT LIKE 'demo\_minor\_%';

-- Followers (follow.started), spread over the last three days.
CREATE TEMP TABLE new_followers(username text, hours_ago int);
INSERT INTO new_followers VALUES ('demo_rohan', 70), ('demo_sofia', 52), ('demo_lucia', 41), ('demo_zara', 30),
  ('demo_yuki', 19), ('demo_ananya', 8), ('demo_arjun', 2);
INSERT INTO follows(follower_id, followee_id, state, created_at, source)
SELECT a.user_id, (SELECT user_id FROM t), 'active', now() - make_interval(hours => f.hours_ago), 'discover'
  FROM new_followers f JOIN actors a USING (username)
ON CONFLICT (follower_id, followee_id) DO NOTHING;
INSERT INTO notifications(notification_id, recipient_id, actor_id, event, target_id, created_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), a.user_id, 'follow.started', a.user_id, now() - make_interval(hours => f.hours_ago)
  FROM new_followers f JOIN actors a USING (username)
ON CONFLICT (recipient_id, actor_id, event) DO UPDATE SET target_id = excluded.target_id, created_at = excluded.created_at, read_at = NULL;

-- Friend requests waiting for an answer (friend.requested).
CREATE TEMP TABLE new_requests(username text, hours_ago int);
INSERT INTO new_requests VALUES ('demo_mira', 26), ('demo_kenji', 11), ('demo_subhasini', 4);
INSERT INTO friendships(friendship_id, user_low_id, user_high_id, requested_by, status, created_at, updated_at)
SELECT gen_random_uuid(), LEAST(a.user_id, (SELECT user_id FROM t)), GREATEST(a.user_id, (SELECT user_id FROM t)), a.user_id,
       'pending', now() - make_interval(hours => r.hours_ago), now() - make_interval(hours => r.hours_ago)
  FROM new_requests r JOIN actors a USING (username)
ON CONFLICT (user_low_id, user_high_id) DO NOTHING;
INSERT INTO notifications(notification_id, recipient_id, actor_id, event, target_id, created_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), a.user_id, 'friend.requested', f.friendship_id, f.created_at
  FROM new_requests r JOIN actors a USING (username)
  JOIN friendships f ON f.user_low_id = LEAST(a.user_id, (SELECT user_id FROM t)) AND f.user_high_id = GREATEST(a.user_id, (SELECT user_id FROM t))
 WHERE f.status = 'pending'
ON CONFLICT (recipient_id, actor_id, event) DO UPDATE SET target_id = excluded.target_id, created_at = excluded.created_at, read_at = NULL;

-- One accepted friendship (friend.accepted): the target asked, Maya accepted.
INSERT INTO friendships(friendship_id, user_low_id, user_high_id, requested_by, status, created_at, responded_at, updated_at)
SELECT gen_random_uuid(), LEAST(a.user_id, (SELECT user_id FROM t)), GREATEST(a.user_id, (SELECT user_id FROM t)), (SELECT user_id FROM t),
       'accepted', now() - interval '20 hours', now() - interval '6 hours', now() - interval '6 hours'
  FROM actors a WHERE a.username = 'demo_maya'
ON CONFLICT (user_low_id, user_high_id) DO NOTHING;
INSERT INTO notifications(notification_id, recipient_id, actor_id, event, target_id, created_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), a.user_id, 'friend.accepted', a.user_id, now() - interval '6 hours'
  FROM actors a WHERE a.username = 'demo_maya'
ON CONFLICT (recipient_id, actor_id, event) DO UPDATE SET target_id = excluded.target_id, created_at = excluded.created_at, read_at = NULL;

-- Profile visitors (the Visitors number). Each person counts once, like the API.
CREATE TEMP TABLE new_visits(username text, hours_ago int);
INSERT INTO new_visits VALUES ('demo_rohan', 71), ('demo_sofia', 60), ('demo_lucia', 44), ('demo_zara', 33), ('demo_yuki', 21),
  ('demo_ananya', 12), ('demo_arjun', 5), ('demo_mira', 27), ('demo_kenji', 12), ('demo_theo', 9), ('demo_ishaan', 7),
  ('demo_jiwoo', 3), ('demo_lulilly', 1), ('demo_maya', 22);
INSERT INTO profile_visits(profile_id, visitor_id, first_visited_at)
SELECT (SELECT user_id FROM t), a.user_id, now() - make_interval(hours => v.hours_ago)
  FROM new_visits v JOIN actors a USING (username)
ON CONFLICT (profile_id, visitor_id) DO NOTHING;
INSERT INTO profile_visit_counts(profile_id, slot, visitors)
SELECT (SELECT user_id FROM t), 0,
       (SELECT count(*) FROM profile_visits WHERE profile_id = (SELECT user_id FROM t))
       - coalesce((SELECT sum(visitors) FROM profile_visit_counts WHERE profile_id = (SELECT user_id FROM t) AND slot <> 0), 0)
ON CONFLICT (profile_id, slot) DO UPDATE SET visitors = excluded.visitors;

-- One follow request waiting for approval (follow.requested), for the Followers screen's request section.
INSERT INTO follows(follower_id, followee_id, state, created_at, source)
SELECT a.user_id, (SELECT user_id FROM t), 'pending', now() - interval '3 hours', 'discover'
  FROM actors a WHERE a.username = 'demo_theo'
ON CONFLICT (follower_id, followee_id) DO NOTHING;
INSERT INTO notifications(notification_id, recipient_id, actor_id, event, target_id, created_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), a.user_id, 'follow.requested', a.user_id, now() - interval '3 hours'
  FROM actors a WHERE a.username = 'demo_theo' AND EXISTS (SELECT 1 FROM follows WHERE follower_id = a.user_id AND followee_id = (SELECT user_id FROM t) AND state = 'pending')
ON CONFLICT (recipient_id, actor_id, event) DO UPDATE SET target_id = excluded.target_id, created_at = excluded.created_at, read_at = NULL;

-- Three people the member follows, for the Following screen.
INSERT INTO follows(follower_id, followee_id, state, created_at, source)
SELECT (SELECT user_id FROM t), a.user_id, 'active', now() - make_interval(hours => f.hours_ago), 'discover'
  FROM (VALUES ('demo_mira', 40), ('demo_kenji', 20), ('demo_subhasini', 6)) f(username, hours_ago) JOIN actors a USING (username)
ON CONFLICT (follower_id, followee_id) DO NOTHING;

-- Two active stories (24 hours) with viewers, for My stories and the viewers list. A re-run adds them again only
-- once they have expired.
CREATE TEMP TABLE starter_stories(body text, background text, audience text, hours_ago int);
INSERT INTO starter_stories VALUES ('Golden hour from my window 🌇', 'peach', 'followers', 5), ('Coffee first, then everything else ☕', 'lime', 'public', 1);
INSERT INTO stories(story_id, author_id, body, background, audience, created_at, expires_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), s.body, s.background, s.audience,
       now() - make_interval(hours => s.hours_ago), now() - make_interval(hours => s.hours_ago) + interval '24 hours'
  FROM starter_stories s
 WHERE NOT EXISTS (SELECT 1 FROM stories x WHERE x.author_id = (SELECT user_id FROM t) AND x.body = s.body AND x.deleted_at IS NULL AND x.expires_at > now());
INSERT INTO story_views(story_id, viewer_id, viewed_at)
SELECT x.story_id, a.user_id, now() - make_interval(mins => v.mins_ago)
  FROM (VALUES ('Golden hour from my window 🌇', 'demo_rohan', 200), ('Golden hour from my window 🌇', 'demo_sofia', 150), ('Golden hour from my window 🌇', 'demo_zara', 40),
               ('Coffee first, then everything else ☕', 'demo_lucia', 35), ('Coffee first, then everything else ☕', 'demo_yuki', 12)) v(body, username, mins_ago)
  JOIN actors a USING (username)
  JOIN stories x ON x.author_id = (SELECT user_id FROM t) AND x.body = v.body AND x.deleted_at IS NULL AND x.expires_at > now()
ON CONFLICT (story_id, viewer_id) DO NOTHING;

-- For trying "followers can open a member's followers, following and stories": demo_arjun and demo_lucia each get a
-- few followers and a few people they follow among the demo people (so their lists are not empty), one story for
-- followers and one public story. The member does NOT follow either of them (they follow the member), so open their
-- profile, see the lists and stories locked, tap Follow, and the Followers, Following and Stories cells open at once.
-- Adults only (the actors list), and only the demo people take part. A story is added again only after it has expired.
CREATE TEMP TABLE demo_graph(follower text, followee text, hours_ago int);
INSERT INTO demo_graph VALUES
  ('demo_rohan', 'demo_arjun', 60), ('demo_sofia', 'demo_arjun', 30), ('demo_zara', 'demo_arjun', 12),
  ('demo_arjun', 'demo_mira', 50), ('demo_arjun', 'demo_kenji', 20), ('demo_arjun', 'demo_lucia', 7),
  ('demo_yuki', 'demo_lucia', 40), ('demo_ananya', 'demo_lucia', 15),
  ('demo_lucia', 'demo_sofia', 45), ('demo_lucia', 'demo_theo', 25), ('demo_lucia', 'demo_arjun', 5);
INSERT INTO follows(follower_id, followee_id, state, created_at, source)
SELECT a.user_id, b.user_id, 'active', now() - make_interval(hours => g.hours_ago), 'discover'
  FROM demo_graph g JOIN actors a ON a.username = g.follower JOIN actors b ON b.username = g.followee
ON CONFLICT (follower_id, followee_id) DO NOTHING;
CREATE TEMP TABLE demo_stories(username text, body text, background text, audience text, hours_ago int);
INSERT INTO demo_stories VALUES
  ('demo_arjun', 'New beat dropping tonight 🎧', 'peach', 'followers', 4), ('demo_arjun', 'Studio window, 2am view', 'lime', 'public', 2),
  ('demo_lucia', 'Sunday market haul 🍑', 'pink', 'followers', 6), ('demo_lucia', 'Photo walk tomorrow, who is in?', 'mint', 'public', 3);
INSERT INTO stories(story_id, author_id, body, background, audience, created_at, expires_at)
SELECT gen_random_uuid(), a.user_id, s.body, s.background, s.audience,
       now() - make_interval(hours => s.hours_ago), now() - make_interval(hours => s.hours_ago) + interval '24 hours'
  FROM demo_stories s JOIN actors a USING (username)
 WHERE NOT EXISTS (SELECT 1 FROM stories x WHERE x.author_id = a.user_id AND x.body = s.body AND x.deleted_at IS NULL AND x.expires_at > now());

-- Two starter posts from the member, so other people have something to react to and comment on.
CREATE TEMP TABLE starter_posts(key text, body text, hours_ago int);
INSERT INTO starter_posts VALUES
  ('one', 'Hello Hiyall 👋 first post from my test account. Say hi!', 30),
  ('two', 'Anyone up for a photography walk this weekend? 📸', 9);
INSERT INTO posts(post_id, author_id, body, audience, created_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), s.body, 'public', now() - make_interval(hours => s.hours_ago)
  FROM starter_posts s
 WHERE NOT EXISTS (SELECT 1 FROM posts p WHERE p.author_id = (SELECT user_id FROM t) AND p.body = s.body AND p.deleted_at IS NULL);
CREATE TEMP TABLE tp AS
SELECT s.key, p.post_id FROM starter_posts s
  JOIN posts p ON p.author_id = (SELECT user_id FROM t) AND p.body = s.body AND p.deleted_at IS NULL;

-- Reactions (post.reacted), one per person per post.
CREATE TEMP TABLE new_reactions(key text, username text, reaction text, hours_ago int);
INSERT INTO new_reactions VALUES ('one', 'demo_zara', 'heart', 28), ('one', 'demo_rohan', 'fire', 25), ('one', 'demo_sofia', 'laugh', 22),
  ('one', 'demo_kenji', 'wow', 15), ('one', 'demo_yuki', 'heart', 10),
  ('two', 'demo_lucia', 'heart', 8), ('two', 'demo_theo', 'fire', 6), ('two', 'demo_ananya', 'heart', 3);
INSERT INTO post_reactions(post_id, user_id, reaction, created_at)
SELECT tp.post_id, a.user_id, r.reaction, now() - make_interval(hours => r.hours_ago)
  FROM new_reactions r JOIN tp USING (key) JOIN actors a USING (username)
ON CONFLICT (post_id, user_id) DO NOTHING;
INSERT INTO notifications(notification_id, recipient_id, actor_id, event, target_id, created_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), a.user_id, 'post.reacted', tp.post_id, now() - make_interval(hours => r.hours_ago)
  FROM new_reactions r JOIN tp USING (key) JOIN actors a USING (username)
ON CONFLICT (recipient_id, actor_id, event) DO UPDATE SET target_id = excluded.target_id, created_at = excluded.created_at, read_at = NULL;

-- Comments (post.commented).
CREATE TEMP TABLE new_comments(key text, username text, body text, hours_ago int);
INSERT INTO new_comments VALUES ('one', 'demo_sofia', 'Welcome to Hiyall! 🎉', 21), ('one', 'demo_rohan', 'Love the vibe already', 24),
  ('two', 'demo_arjun', 'I''m in! Which spot?', 2), ('two', 'demo_lucia', 'Count me in 📸', 5);
INSERT INTO comments(comment_id, post_id, author_id, body, created_at)
SELECT gen_random_uuid(), tp.post_id, a.user_id, c.body, now() - make_interval(hours => c.hours_ago)
  FROM new_comments c JOIN tp USING (key) JOIN actors a USING (username)
 WHERE NOT EXISTS (SELECT 1 FROM comments x WHERE x.post_id = tp.post_id AND x.author_id = a.user_id AND x.body = c.body);
INSERT INTO notifications(notification_id, recipient_id, actor_id, event, target_id, created_at)
SELECT gen_random_uuid(), (SELECT user_id FROM t), a.user_id, 'post.commented', tp.post_id, now() - make_interval(hours => c.hours_ago)
  FROM new_comments c JOIN tp USING (key) JOIN actors a USING (username)
ON CONFLICT (recipient_id, actor_id, event) DO UPDATE SET target_id = excluded.target_id, created_at = excluded.created_at, read_at = NULL;

-- Counters: slot 0 carries whatever the real rows say, minus anything the API later added on other slots.
INSERT INTO post_counters(post_id, slot, reactions, comments)
SELECT tp.post_id, 0,
       (SELECT count(*) FROM post_reactions WHERE post_id = tp.post_id)
         - coalesce((SELECT sum(reactions) FROM post_counters WHERE post_id = tp.post_id AND slot <> 0), 0),
       (SELECT count(*) FROM comments WHERE post_id = tp.post_id AND deleted_at IS NULL AND NOT hidden)
         - coalesce((SELECT sum(comments) FROM post_counters WHERE post_id = tp.post_id AND slot <> 0), 0)
  FROM tp
ON CONFLICT (post_id, slot) DO UPDATE SET reactions = excluded.reactions, comments = excluded.comments;

COMMIT;

SELECT 'followers' AS what, count(*)::text AS n FROM follows WHERE followee_id = (SELECT user_id FROM t) AND state = 'active'
UNION ALL SELECT 'friends', count(*)::text FROM friendships WHERE status = 'accepted' AND (SELECT user_id FROM t) IN (user_low_id, user_high_id)
UNION ALL SELECT 'friend requests waiting', count(*)::text FROM friendships WHERE status = 'pending' AND requested_by <> (SELECT user_id FROM t) AND (SELECT user_id FROM t) IN (user_low_id, user_high_id)
UNION ALL SELECT 'visitors', coalesce(sum(visitors), 0)::text FROM profile_visit_counts WHERE profile_id = (SELECT user_id FROM t)
UNION ALL SELECT 'follow requests waiting', count(*)::text FROM follows WHERE followee_id = (SELECT user_id FROM t) AND state = 'pending'
UNION ALL SELECT 'following', count(*)::text FROM follows WHERE follower_id = (SELECT user_id FROM t) AND state = 'active'
UNION ALL SELECT 'active stories', count(*)::text FROM stories WHERE author_id = (SELECT user_id FROM t) AND deleted_at IS NULL AND expires_at > now()
UNION ALL SELECT 'posts', count(*)::text FROM posts WHERE author_id = (SELECT user_id FROM t) AND deleted_at IS NULL
UNION ALL SELECT 'unread activity', count(*)::text FROM notifications WHERE recipient_id = (SELECT user_id FROM t) AND read_at IS NULL;
