#!/usr/bin/env bash
# Places Anjali, Niko, Kai and the demo_ people (adults and two minors) from scripts/dev/demo-people.sql around a centre in the
# LOCAL development database, so Discover > Nearby has people to show.
#
#   ./scripts/dev/seed-demo-nearby.sh [LAT LON]        default centre 12.9716 77.5946 (Bengaluru)
#
# Use the point you will share from the app as the centre. Everyone lands between about 0.5 and
# 40 km from it, spread around the compass, with coordinates already rounded to the grid the
# server stores (2 decimals for adults, 1 for minors, who are only shown to other minors) and a
# fresh updated_at (a shared point counts for 24 hours, so run this again if Nearby goes quiet).
# Safe to re-run. Touches only the local `hiyall` database.
# Run ./scripts/dev-api.sh (which applies migrations) and ./scripts/dev/seed-demo-people.sh first.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$task_root/scripts/env.sh"

if [[ $# -ne 0 && $# -ne 2 ]]; then
  echo "usage: $0 [LAT LON]" >&2
  exit 2
fi
lat="${1:-12.9716}"
lon="${2:-77.5946}"
number='^-?[0-9]+(\.[0-9]+)?$'
if ! [[ "$lat" =~ $number && "$lon" =~ $number ]]; then
  echo "LAT and LON must be plain decimal numbers, for example 12.9716 77.5946" >&2
  exit 2
fi
# Range check in awk so a value like 91 or 181 is refused before anything runs.
if ! awk -v lat="$lat" -v lon="$lon" 'BEGIN { exit !(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) }'; then
  echo "LAT must be between -90 and 90 and LON between -180 and 180" >&2
  exit 2
fi

db=(psql -h "$task_root/.runtime/pgsocket" -p 55432 -U hiyall -d hiyall)
if [[ "$("${db[@]}" -Atc "SELECT to_regclass('public.user_locations') IS NOT NULL")" != "t" ]]; then
  echo "The user_locations table is missing: start ./scripts/dev-api.sh once so migration 0016 is applied." >&2
  exit 1
fi
"${db[@]}" -q -v lat="$lat" -v lon="$lon" -f "$task_root/scripts/dev/demo-nearby.sql"
