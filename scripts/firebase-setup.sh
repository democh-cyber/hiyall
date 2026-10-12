#!/usr/bin/env bash
# Connects Hiyall to a Firebase project and writes the local config the app and API read.
#
#   firebase login                                   # once, in a browser
#   ./scripts/firebase-setup.sh <project-id>          # existing project
#   ./scripts/firebase-setup.sh <project-id> --create # create it first
#
# Options:
#   --create                 create the Firebase project (IDs are global; pick an unused one)
#   --support-email <email>  shown on Google's sign-in consent screen; defaults to the
#                            account signed in to the Firebase CLI
#   --sha <fingerprint>      extra Android signing certificate (SHA-1 or SHA-256), e.g. the
#                            release or Play app-signing key; repeatable
#
# Safe to re-run: existing apps and fingerprints are reused. What it does:
#   1. registers the web, Android (app.hiyall.hiyall) and iOS (app.hiyall.hiyall) apps;
#   2. adds the Android debug keystore's fingerprints (needed for Google sign-in) and any --sha;
#   3. turns on Email/Password and Google sign-in;
#   4. writes config/firebase.local.json and apps/mobile/ios/Flutter/Firebase.xcconfig
#      (both git-ignored), which dev-api.sh and dev-mobile.sh pick up.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"

app_id_bundle="app.hiyall.hiyall"
project="" create=false support_email="" extra_shas=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) create=true ;;
    --support-email) support_email="${2:?--support-email needs a value}"; shift ;;
    --sha) extra_shas+=("${2:?--sha needs a value}"); shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "Unknown option $1" >&2; exit 2 ;;
    *) project="$1" ;;
  esac
  shift
done
if [[ ! "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  echo "Usage: $0 <project-id> [--create] [--support-email <email>] [--sha <fingerprint>]" >&2
  echo "Project IDs are 6-30 lowercase letters, digits or hyphens, starting with a letter." >&2
  exit 2
fi
command -v firebase >/dev/null || { echo "Firebase CLI missing: npm install -g firebase-tools" >&2; exit 1; }

# Reads a field from the CLI's --json output on stdin.
json() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);if(o.status!=="success"){console.error(o.error||"command failed");process.exit(1)}const v=('"$1"')(o.result);if(v===undefined||v===null){process.exit(3)}console.log(v)})'; }
fb() { firebase --non-interactive --project "$project" "$@"; }

account="$(firebase login:list --json 2>/dev/null | json 'r=>r[0]&&r[0].user&&r[0].user.email' 2>/dev/null || true)"
if [[ -z "$account" ]]; then
  echo "The Firebase CLI isn't signed in. Run: firebase login" >&2
  exit 1
fi
support_email="${support_email:-$account}"
echo "Signed in as $account; project $project"

if $create; then
  echo "Creating project $project..."
  firebase --non-interactive projects:create "$project" --display-name Hiyall
fi

# Returns the app id for a platform, creating the app when it doesn't exist.
ensure_app() {
  local platform="$1" name="$2" match="$3" flag="${4:-}" id
  id="$(fb apps:list "$platform" --json | json "r=>{const a=r.find(a=>${match});return a&&a.appId}" || true)"
  if [[ -z "$id" ]]; then
    echo "Registering $name..." >&2
    if [[ -n "$flag" ]]; then
      id="$(fb apps:create "$platform" "$name" "$flag" "$app_id_bundle" --json | json 'r=>r.appId')"
    else
      id="$(fb apps:create "$platform" "$name" --json | json 'r=>r.appId')"
    fi
  fi
  echo "$id"
}
web_id="$(ensure_app WEB "Hiyall Web" 'a.displayName==="Hiyall Web"')"
android_id="$(ensure_app ANDROID "Hiyall Android" "a.packageName===\"$app_id_bundle\"" --package-name)"
ios_id="$(ensure_app IOS "Hiyall iOS" "a.bundleId===\"$app_id_bundle\"" --bundle-id)"
echo "Apps: web $web_id, android $android_id, ios $ios_id"

# Android signing fingerprints. Google sign-in on Android fails without the
# fingerprint of the key that signed the build.
shas=("${extra_shas[@]+"${extra_shas[@]}"}")
debug_keystore="$HOME/.android/debug.keystore"
if [[ -f "$debug_keystore" ]] && command -v keytool >/dev/null; then
  # The debug keystore's password is Android's public default, not a secret.
  while read -r sha; do shas+=("$sha"); done < <(
    keytool -list -v -keystore "$debug_keystore" -alias androiddebugkey -storepass android -keypass android 2>/dev/null |
      awk '/SHA1:|SHA256:/ {print $2}')
else
  echo "No Android debug keystore yet (it appears after the first Android build); re-run then to add its fingerprint."
fi
if [[ ${#shas[@]} -gt 0 ]]; then
  known="$(fb apps:android:sha:list "$android_id" --json | json 'r=>r.map(c=>c.shaHash.toLowerCase()).join(" ")' || true)"
  for sha in "${shas[@]}"; do
    plain="$(echo "$sha" | tr -d ':' | tr 'A-F' 'a-f')"
    if [[ " $known " == *" $plain "* ]]; then continue; fi
    echo "Adding Android fingerprint $sha"
    fb apps:android:sha:create "$android_id" "$plain" >/dev/null
  done
fi

# Sign-in methods, through the CLI's auth deploy with a throwaway config.
deploy_dir="$(mktemp -d)"
trap 'rm -rf "$deploy_dir"' EXIT
node -e 'const [dir,email]=process.argv.slice(1);require("fs").writeFileSync(dir+"/firebase.json",JSON.stringify({auth:{providers:{emailPassword:true,googleSignIn:{oAuthBrandDisplayName:"Hiyall",supportEmail:email}}}},null,2))' "$deploy_dir" "$support_email"
echo "Turning on Email/Password and Google sign-in..."
(cd "$deploy_dir" && firebase --non-interactive --project "$project" deploy --only auth --config firebase.json)

# Config for the app and API. Downloaded after sign-in is on so the iOS file
# includes the Google OAuth client.
for platform in web android ios; do
  id_var="${platform}_id"
  fb apps:sdkconfig "$platform" "${!id_var}" --json > "$deploy_dir/$platform.json"
done
node "$task_root/scripts/firebase_app_config.mjs" "$deploy_dir/web.json" "$deploy_dir/android.json" "$deploy_dir/ios.json" "$android_id" "$ios_id"

cat <<EOF

Done. Next:
  ./scripts/dev-api.sh       # API verifies Firebase ID tokens for $project
  ./scripts/dev-mobile.sh    # app at http://localhost:49321 with Firebase sign-in
Still in the Firebase console (Authentication > Settings):
  - Password policy: require at least 8 characters, to match the app.
  - Authorized domains: add your production web domain before launch.
EOF
