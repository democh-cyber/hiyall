-- Local fixtures only; requires the Anjali and Niko development accounts (created by the API on start).
\set ON_ERROR_STOP on
DO $$ BEGIN
 IF current_database()<>'hiyall' THEN RAISE EXCEPTION 'demo spaces require local hiyall database';END IF;
END $$;
BEGIN;
INSERT INTO spaces(space_id,owner_id,kind,title,description,rules,visibility,capacity,timezone)
SELECT '019a6000-0000-7000-8000-000000000001',p.user_id,'community','Night owl cafe','Books, playlists and the small things that make a day.','Keep it kind. No spam or unsolicited contact.','public',100,'UTC'
FROM profiles p JOIN onboarding o USING(user_id) WHERE p.username='niko' AND o.completed_at IS NOT NULL
ON CONFLICT(space_id) DO NOTHING;
INSERT INTO spaces(space_id,owner_id,kind,title,description,rules,visibility,capacity,timezone)
SELECT '019a6000-0000-7000-8000-000000000002',p.user_id,'community','Make something together','A small circle for sharing what you are building. Join requests are approved by Anjali.','Share ideas and useful feedback.','private',50,'Asia/Kolkata'
FROM profiles p JOIN onboarding o USING(user_id) WHERE p.username='anjali' AND o.completed_at IS NOT NULL
ON CONFLICT(space_id) DO NOTHING;
INSERT INTO spaces(space_id,owner_id,parent_id,kind,title,description,rules,visibility,capacity,starts_at,ends_at,timezone)
SELECT '019a6000-0000-7000-8000-000000000003',s.owner_id,s.space_id,'moment','One song that gets you','A one-hour Moment. Share a song and the story behind it.','Listen with curiosity.','public',20,now()-interval '5 minutes',now()+interval '55 minutes','UTC'
FROM spaces s WHERE s.space_id='019a6000-0000-7000-8000-000000000001'
ON CONFLICT(space_id) DO NOTHING;
INSERT INTO spaces(space_id,owner_id,kind,title,description,rules,visibility,capacity,starts_at,ends_at,timezone,location)
SELECT '019a6000-0000-7000-8000-000000000004',s.owner_id,'event','Weekend creative check-in','Bring one idea, leave with a little momentum. A demo event for trying RSVP.','Be respectful of everyone’s time.','public',30,now()+interval '2 days',now()+interval '2 days 1 hour','Asia/Kolkata','Online · demo meeting'
FROM spaces s WHERE s.space_id='019a6000-0000-7000-8000-000000000002'
ON CONFLICT(space_id) DO NOTHING;
INSERT INTO space_members(space_id,user_id,role,state)
SELECT space_id,owner_id,'owner','active' FROM spaces WHERE space_id IN ('019a6000-0000-7000-8000-000000000001','019a6000-0000-7000-8000-000000000002','019a6000-0000-7000-8000-000000000003','019a6000-0000-7000-8000-000000000004')
ON CONFLICT(space_id,user_id) DO NOTHING;
INSERT INTO space_entries(entry_id,space_id,author_id,body)
SELECT '019a6000-0000-7000-8000-000000000005',s.space_id,s.owner_id,'Welcome to the cafe. What have you been reading or listening to lately?'
FROM spaces s WHERE s.space_id='019a6000-0000-7000-8000-000000000001'
ON CONFLICT(entry_id) DO NOTHING;
COMMIT;
