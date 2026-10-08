-- Demo people for the LOCAL development database only. Never run against
-- production: it grants adult discovery eligibility without age assurance.
\set ON_ERROR_STOP on
DO $$ BEGIN
  IF current_database() <> 'kairova' THEN
    RAISE EXCEPTION 'demo people are only for the local development database (kairova)';
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

INSERT INTO users(user_id) SELECT id FROM demo ON CONFLICT DO NOTHING;

INSERT INTO profiles(user_id,username,data)
SELECT id, username, jsonb_build_object(
  'username',username,'displayName',name,'headline',headline,'bio',bio,'quote','',
  'country',country,'region','','city','','timezone','UTC','locale','en',
  'currentVibe',vibe,'interests',interests,'languages',languages,
  'pronouns','','profession','','education','',
  'profileAudience','public','profileAccent',accent,'profilePattern','glow','avatarFrame','minimal')
FROM demo
ON CONFLICT (user_id) DO UPDATE SET data=excluded.data, version=profiles.version+1, updated_at=now();

INSERT INTO privacy_settings(user_id,data)
SELECT id, jsonb_build_object(
  'profileAudience','public','messagesFrom','friends','followPolicy',follow_policy,
  'requestsFrom','everyone','storyAudience','friends','activityAudience','nobody',
  'onlineAudience','nobody','lastSeenAudience','nobody','locationAudience','everyone',
  'commentsFrom','friends','mentionsFrom','friends',
  'discoverable',true,'showInterestOverlap',true,'readReceipts',false,
  'fieldAudiences',jsonb_build_object(
    'pronouns','nobody','location','everyone','profession','nobody','education','nobody',
    'website','nobody','timezone','nobody','languages','everyone','interests','everyone',
    'vibe','everyone','connections','everyone'))
FROM demo
ON CONFLICT (user_id) DO UPDATE SET data=excluded.data, version=privacy_settings.version+1, updated_at=now();

-- Demo people plus the two development sign-in accounts can use discovery locally.
INSERT INTO discovery_eligibility(user_id,age_group,confirmed_at,valid_until)
SELECT id,'adult',now(),now()+interval '1 year' FROM demo
UNION ALL
SELECT user_id,'adult',now(),now()+interval '1 year' FROM users
 WHERE user_id IN ('019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000002')
ON CONFLICT (user_id) DO UPDATE SET age_group='adult',confirmed_at=now(),valid_until=now()+interval '1 year';
COMMIT;

SELECT count(*) AS demo_people_in_discovery FROM profiles WHERE username LIKE 'demo\_%';
