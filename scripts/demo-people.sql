-- Demo people for the LOCAL development database only. Never run against
-- production: these are fake accounts with completed onboarding and open
-- profiles. Every member is discoverable by default, so no eligibility is
-- granted (discovery_eligibility is retired and nothing reads it).
-- Each person has a gender and a stored birth date (ages computed from today).
-- The 16 demo_ people are adults aged 18 to 40; demo_minor_mika (15) and
-- demo_minor_noor (16) are minors with the minor defaults, so they only see and
-- are seen by other minors (Kai, the minor development account). Birth dates move
-- with the clock: running this again sets them to the same ages as today.
\set ON_ERROR_STOP on
DO $$ BEGIN
  IF current_database() <> 'hiyall' THEN
    RAISE EXCEPTION 'demo people are only for the local development database (hiyall)';
  END IF;
END $$;

BEGIN;
CREATE TEMP TABLE demo(
  id uuid, username text, name text, headline text, bio text, country text,
  vibe text, interests jsonb, languages jsonb, follow_policy text, accent text
) ON COMMIT DROP;

INSERT INTO demo VALUES
('019a4000-0000-7000-8000-000000000101','demo_subhasini','Subhasini','learning korean through dramas','K-drama marathons and bad translations. Teach me slang?','IN','Chill','["Movies","Music","Learning"]','[{"code":"en","level":"fluent"},{"code":"ko","level":"basic"},{"code":"hi","level":"native"}]','everyone','violet'),
('019a4000-0000-7000-8000-000000000102','demo_lulilly','Lulilly','hello!','Sketchbook always in my bag. Say hi.','IN','Creative','["Art","Photography"]','[{"code":"en","level":"conversational"}]','approval','lime'),
('019a4000-0000-7000-8000-000000000103','demo_mira','Mira','film photos + late night ramen','Seoul, 35mm, and too much coffee.','KR','Night owl','["Photography","Food","Travel"]','[{"code":"ko","level":"native"},{"code":"en","level":"conversational"}]','everyone','cyan'),
('019a4000-0000-7000-8000-000000000104','demo_arjun','Arjun','lofi beats and bad puns','Making beats at 2am. Producer in progress.','IN','Night owl','["Music","Tech"]','[{"code":"hi","level":"native"},{"code":"en","level":"fluent"}]','everyone','lime'),
('019a4000-0000-7000-8000-000000000105','demo_yuki','Yuki','drawing every day this year','Day 212 of daily sketches. Manga + watercolor.','JP','Creative','["Art","Books"]','[{"code":"ja","level":"native"},{"code":"en","level":"basic"}]','approval','violet'),
('019a4000-0000-7000-8000-000000000106','demo_bangtan_soul','Bangtan soul','love yourself','ARMY forever. Looking for concert buddies.','IN','Chill','["Music","Movies"]','[{"code":"en","level":"fluent"},{"code":"ko","level":"basic"}]','everyone','violet'),
('019a4000-0000-7000-8000-000000000107','demo_lucia','Lucía','tapas, trains and tangents','Interrailing across Europe on a student budget.','ES','Explorer','["Travel","Food","Photography"]','[{"code":"es","level":"native"},{"code":"en","level":"fluent"},{"code":"fr","level":"basic"}]','everyone','lime'),
('019a4000-0000-7000-8000-000000000108','demo_theo','Théo','speedrunning my way through uni','Game dev student. Ask me about frame data.','FR','Active','["Gaming","Tech"]','[{"code":"fr","level":"native"},{"code":"en","level":"fluent"}]','approval','cyan'),
('019a4000-0000-7000-8000-000000000109','demo_ananya','Ananya','currently reading: everything','Annotating books so you don''t have to.','IN','Bookish','["Books","Learning"]','[{"code":"en","level":"fluent"},{"code":"hi","level":"native"},{"code":"ja","level":"basic"}]','everyone','violet'),
('019a4000-0000-7000-8000-000000000110','demo_kenji','Kenji','gym, code, repeat','Backend dev who lifts. Swap playlists?','JP','Active','["Fitness","Tech","Music"]','[{"code":"ja","level":"native"},{"code":"en","level":"conversational"}]','everyone','lime'),
('019a4000-0000-7000-8000-000000000111','demo_zara','Zara','thrift finds and film nights','Charity-shop fits and A24 opinions.','GB','Creative','["Movies","Art"]','[{"code":"en","level":"native"},{"code":"es","level":"basic"}]','approval','cyan'),
('019a4000-0000-7000-8000-000000000112','demo_rohan','Rohan','chai over coffee, always','Engineering student. Will debate chai vs coffee.','IN','Chill','["Food","Tech","Gaming"]','[{"code":"hi","level":"native"},{"code":"en","level":"fluent"}]','everyone','lime'),
('019a4000-0000-7000-8000-000000000113','demo_sofia','Sofia','learning hindi one song at a time','Bollywood soundtracks are my teacher now.','BR','Explorer','["Music","Learning","Travel"]','[{"code":"pt","level":"native"},{"code":"en","level":"fluent"},{"code":"hi","level":"basic"}]','everyone','violet'),
('019a4000-0000-7000-8000-000000000114','demo_jiwoo','Jiwoo','bubble tea taste tester','Ranking every boba shop in Busan.','KR','Chill','["Food","Photography"]','[{"code":"ko","level":"native"},{"code":"en","level":"basic"},{"code":"ja","level":"conversational"}]','approval','cyan'),
('019a4000-0000-7000-8000-000000000115','demo_maya','Maya','sunrise hikes > sleeping in','Trail runner, terrible at sleeping in.','US','Active','["Fitness","Travel"]','[{"code":"en","level":"native"},{"code":"es","level":"conversational"}]','everyone','lime'),
('019a4000-0000-7000-8000-000000000116','demo_ishaan','Ishaan','building tiny robots','Arduino, 3D printing and too many wires.','IN','Night owl','["Tech","Learning","Gaming"]','[{"code":"en","level":"fluent"},{"code":"hi","level":"native"}]','everyone','violet');

-- Two minors, then a gender and an age for everyone.
INSERT INTO demo VALUES
('019a4000-0000-7000-8000-000000000117','demo_minor_mika','Mika','drawing in the margins','Comics, cats and school-night playlists.','JP','Creative','["Art","Music"]','[{"code":"ja","level":"native"},{"code":"en","level":"basic"}]','approval','violet'),
('019a4000-0000-7000-8000-000000000118','demo_minor_noor','Noor','robotics club president','Building a rover for the science fair.','GB','Active','["Tech","Learning","Gaming"]','[{"code":"en","level":"native"},{"code":"ar","level":"conversational"}]','approval','cyan');
ALTER TABLE demo ADD COLUMN gender text, ADD COLUMN age int;
UPDATE demo d SET gender=x.gender, age=x.age FROM (VALUES
 ('demo_subhasini','woman',22),('demo_lulilly','woman',19),('demo_mira','woman',27),('demo_arjun','man',24),
 ('demo_yuki','nonbinary',21),('demo_bangtan_soul','nonbinary',23),('demo_lucia','woman',29),('demo_theo','man',20),
 ('demo_ananya','woman',26),('demo_kenji','man',31),('demo_zara','woman',18),('demo_rohan','man',25),
 ('demo_sofia','woman',33),('demo_jiwoo','woman',40),('demo_maya','woman',28),('demo_ishaan','man',35),
 ('demo_minor_mika','woman',15),('demo_minor_noor','nonbinary',16)
) x(username,gender,age) WHERE d.username=x.username;

INSERT INTO users(user_id) SELECT id FROM demo ON CONFLICT DO NOTHING;
-- An account without a completed onboarding row cannot use the API, so demo accounts are complete.
INSERT INTO onboarding(user_id,completed_at,terms_version)
SELECT id, now(), 'fixture' FROM demo
ON CONFLICT (user_id) DO UPDATE SET completed_at=coalesce(onboarding.completed_at, now()), terms_version=coalesce(onboarding.terms_version, 'fixture');

INSERT INTO profiles(user_id,username,data)
SELECT id, username, jsonb_build_object(
  'username',username,'displayName',name,'headline',headline,'bio',bio,'quote','',
  'country',country,'region','','city','','timezone','UTC','locale','en',
  'currentVibe',vibe,'interests',interests,'languages',languages,
  'pronouns','','gender',gender,'profession','','education','',
  'profileAudience','public','profileAccent',accent,'profilePattern','glow','avatarFrame','minimal')
FROM demo
ON CONFLICT (user_id) DO UPDATE SET data=excluded.data, version=profiles.version+1, updated_at=now();

-- The birth dates are private (member_ages): no API returns them. They put the demo people in
-- age bands (see docs/api/19-nearby-and-open-access.md).
INSERT INTO member_ages(user_id,birth_date)
SELECT id, (current_date - make_interval(years => age, months => 3))::date FROM demo
ON CONFLICT (user_id) DO UPDATE SET birth_date=excluded.birth_date;

-- The same open defaults every new account gets (domain.DefaultPrivacy): public,
-- discoverable, presence shown, anyone may message (within the age band), every field
-- visible; the followers and following lists open to followers (friends only for minors). Follows are instant for most; a few demo people
-- keep "approval" (the follow_policy column above) so the request flow can be tried.
-- Minors start with presence hidden and their country shown to friends only.
INSERT INTO privacy_settings(user_id,data)
SELECT id, jsonb_build_object(
  'profileAudience','public','messagesFrom','everyone','followPolicy',follow_policy,
  'requestsFrom','everyone','storyAudience','friends','activityAudience','nobody',
  'onlineAudience',CASE WHEN age < 18 THEN 'nobody' ELSE 'everyone' END,'lastSeenAudience','nobody','locationAudience','nobody',
  'commentsFrom','friends','mentionsFrom','friends',
  'discoverable',true,'showInterestOverlap',true,'readReceipts',false,
  'fieldAudiences',jsonb_build_object(
    'pronouns','everyone','gender','everyone','age','everyone','counts','everyone','location',CASE WHEN age < 18 THEN 'friends' ELSE 'everyone' END,'profession','everyone','education','everyone',
    'website','everyone','timezone','everyone','languages','everyone','interests','everyone',
    'vibe','everyone','connections',CASE WHEN age < 18 THEN 'friends' ELSE 'followers' END))
FROM demo
ON CONFLICT (user_id) DO UPDATE SET data=excluded.data, version=privacy_settings.version+1, updated_at=now();

-- The two development sign-in accounts are open too (they already are unless changed by hand).
UPDATE privacy_settings SET data=data||'{"profileAudience":"public","discoverable":true}'::jsonb, version=version+1, updated_at=now()
 WHERE user_id IN ('019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000002')
   AND (data->>'profileAudience' IS DISTINCT FROM 'public' OR data->>'discoverable' IS DISTINCT FROM 'true');
UPDATE profiles SET data=jsonb_set(data,'{profileAudience}','"public"'), version=version+1, updated_at=now()
 WHERE user_id IN ('019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000002')
   AND data->>'profileAudience' IS DISTINCT FROM 'public';
COMMIT;

SELECT count(*) AS demo_people_in_discovery,
       count(*) FILTER (WHERE age_band(user_id) = 'minor') AS of_them_minors
  FROM profiles WHERE username LIKE 'demo\_%';
