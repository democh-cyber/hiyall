#!/usr/bin/env bash
# Local S3-compatible object storage for photos (SeaweedFS), on 127.0.0.1:8333.
# Credentials are generated once into .runtime/storage/ and never committed.
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/env.sh"
weed="$KAIROVA_TOOLS_DIR/seaweedfs/weed"
if [[ ! -x "$weed" ]]; then
  echo "SeaweedFS not installed at $weed" >&2
  exit 1
fi
state="$task_root/.runtime/storage"
mkdir -p "$state/data"
chmod 700 "$state"
if [[ ! -f "$state/credentials" ]]; then
  umask 077
  printf 'MEDIA_ACCESS_KEY=kairova-dev\nMEDIA_SECRET_KEY=%s\n' "$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)" > "$state/credentials"
fi
source "$state/credentials"
umask 077
cat > "$state/s3.json" <<EOF
{"identities":[{"name":"kairova-api","credentials":[{"accessKey":"$MEDIA_ACCESS_KEY","secretKey":"$MEDIA_SECRET_KEY"}],"actions":["Admin","Read","Write","List","Tagging"]}]}
EOF
# Small volumes keep the local footprint to a few hundred MB.
exec "$weed" server -dir="$state/data" -ip=127.0.0.1 -ip.bind=127.0.0.1 \
  -master.port=9333 -volume.port=8340 -filer.port=8888 \
  -master.volumeSizeLimitMB=64 -volume.max=32 \
  -s3 -s3.port=8333 -s3.config="$state/s3.json"
