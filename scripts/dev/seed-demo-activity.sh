#!/usr/bin/env bash
# Adds demo activity from the demo_ people to one member of the LOCAL development database, so the Activity tab,
# Followers, Friends, Visitors and Pulse have something to show: followers, friend requests waiting for an answer,
# one accepted friendship, one follow request waiting for approval, three people the member follows, two active stories with
# viewers, profile visitors, two starter posts from the member with reactions and comments.
#
#   ./scripts/seed-demo-activity.sh [USERNAME]      default demochannelsh_868
#
# Only adults take part, so USERNAME must be an adult. Safe to re-run (nothing is duplicated, notifications are refreshed
# as unread). Touches only the local `hiyall` database; the SQL refuses to run anywhere else.
# Run ./scripts/dev-api.sh (which applies migrations) and ./scripts/seed-demo-people.sh first.
# The starter posts are written under the member's name; delete them in the app if you do not want them.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [USERNAME]" >&2
  exit 2
fi
target="${1:-demochannelsh_868}"
if ! [[ "$target" =~ ^[a-z0-9_]{3,30}$ ]]; then
  echo "USERNAME must be 3 to 30 lowercase letters, digits or underscores" >&2
  exit 2
fi
psql -h "$task_root/.runtime/pgsocket" -p 55432 -U hiyall -d hiyall -q -v target="$target" -f "$task_root/scripts/demo-activity.sql"
echo "Done for $target. Open the Activity tab (pull to refresh) and Me for the numbers."
