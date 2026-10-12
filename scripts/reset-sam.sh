#!/usr/bin/env bash
# Puts the local "Sam" development fixture back to a brand-new account so the
# onboarding flow can be tried again. Touches only the LOCAL `hiyall` database.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
psql -h "$task_root/.runtime/pgsocket" -p 55432 -U hiyall -d hiyall -v ON_ERROR_STOP=1 -q <<'SQL'
BEGIN;
UPDATE onboarding
   SET age_declared_at = NULL, terms_version = NULL, terms_accepted_at = NULL, completed_at = NULL
 WHERE user_id = '019a4000-0000-7000-8000-0000000000a1';
UPDATE profiles
   SET username = 'member_0000000000a1',
       data = (data - 'country' - 'currentVibe')
              || '{"displayName":"Hiyall member","interests":[],"languages":[],"profileAudience":"public"}'::jsonb,
       version = version + 1, updated_at = now()
 WHERE user_id = '019a4000-0000-7000-8000-0000000000a1';
UPDATE privacy_settings
   SET data = data || '{"profileAudience":"public","discoverable":true,"onlineAudience":"everyone","messagesFrom":"everyone","followPolicy":"everyone"}'::jsonb,
       version = version + 1, updated_at = now()
 WHERE user_id = '019a4000-0000-7000-8000-0000000000a1';
DELETE FROM user_locations WHERE user_id = '019a4000-0000-7000-8000-0000000000a1';
DELETE FROM member_ages WHERE user_id = '019a4000-0000-7000-8000-0000000000a1';
DELETE FROM profile_visits WHERE profile_id = '019a4000-0000-7000-8000-0000000000a1' OR visitor_id = '019a4000-0000-7000-8000-0000000000a1';
DELETE FROM profile_visit_counts WHERE profile_id = '019a4000-0000-7000-8000-0000000000a1';
COMMIT;
SQL
echo "Sam is a new member again. Sign in as Sam to repeat onboarding."
