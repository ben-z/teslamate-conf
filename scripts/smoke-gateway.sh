#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
task_source_sha="${SOURCE_SHA:-$(git rev-parse HEAD)}"
task_image="teslamate-gateway:check-$task_source_sha"
task_container="teslamate-gateway-check-$$"
trap 'docker rm -f "$task_container" >/dev/null 2>&1 || true' EXIT
docker build --build-arg "SOURCE_SHA=$task_source_sha" -t "$task_image" deploy/gateway
docker run -d --name "$task_container" --user 101:101 --read-only \
  --tmpfs /tmp:uid=101,gid=101,size=64m --cap-drop ALL \
  --security-opt no-new-privileges --add-host teslamate:127.0.0.1 \
  -p 127.0.0.1::8080 "$task_image" >/dev/null
task_address="$(docker port "$task_container" 8080/tcp)"
for task_attempt in {1..30}; do
  if curl --silent --fail "http://$task_address/healthz" >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent --show-error --dump-header /dev/stderr \
  "http://$task_address/api/version" | python3 -c \
  'import json,sys; assert json.load(sys.stdin)["version"] == sys.argv[1]' "$task_source_sha"
echo 'Gateway boots as non-root with a read-only filesystem and serves the exact source SHA.'
