#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
task_grafana="teslamate-grafana-check-$$"
trap 'docker rm -f "${task_grafana:?}" >/dev/null 2>&1 || true' EXIT
task_mosquitto_image="$(python3 -c 'import yaml; print(yaml.safe_load(open("docker-compose.yml"))["services"]["mosquitto"]["image"])')"
task_grafana_image="$(python3 -c 'import yaml; print(yaml.safe_load(open("docker-compose.yml"))["services"]["grafana"]["image"])')"

docker run --rm --network none --user 1883:1883 --read-only --cap-drop ALL \
  --security-opt no-new-privileges --tmpfs /tmp:uid=1883,gid=1883,size=16m \
  --tmpfs /mosquitto/data:uid=1883,gid=1883,size=16m \
  --entrypoint sh "$task_mosquitto_image" -ec '
    umask 077
    printf "teslamate:smoke-password\n" > /tmp/mosquitto-password
    mosquitto_passwd -U /tmp/mosquitto-password
    printf "listener 1883\nallow_anonymous false\npassword_file /tmp/mosquitto-password\n" > /tmp/config
    mosquitto -c /tmp/config >/tmp/broker.log 2>&1 &
    task_broker=$!
    trap '\''kill "$task_broker"'\'' EXIT
    sleep 1
    if mosquitto_pub -h 127.0.0.1 -t test -m test 2>/dev/null; then
      echo "Anonymous MQTT unexpectedly succeeded" >&2
      exit 1
    fi
    mosquitto_pub -h 127.0.0.1 -t test -m test -u teslamate -P smoke-password
  '
echo 'MQTT rejects anonymous clients and accepts the configured credentials as non-root.'

docker run -d --name "$task_grafana" --network none --user 472:472 --cap-drop ALL \
  --security-opt no-new-privileges --tmpfs /var/lib/grafana:uid=472,gid=472,size=128m \
  -e DATABASE_USER=smoke -e DATABASE_PASS=smoke -e DATABASE_NAME=teslamate \
  -e DATABASE_HOST=127.0.0.1 -e GF_SECURITY_ADMIN_PASSWORD=smoke-test-only \
  -e GF_SERVER_ROOT_URL=https://teslamate.benzhang.dev/grafana/ \
  -e GF_SERVER_SERVE_FROM_SUB_PATH=true "$task_grafana_image" >/dev/null
for task_attempt in {1..60}; do
  if task_health="$(docker exec "$task_grafana" wget -qO- http://127.0.0.1:3000/grafana/api/health 2>/dev/null)"; then
    printf '%s' "$task_health" | python3 -c 'import json,sys; assert json.load(sys.stdin)["database"] == "ok"'
    echo 'Grafana serves its configured subpath and SQLite health endpoint as non-root.'
    exit 0
  fi
  sleep 1
done
docker logs "$task_grafana" >&2
exit 1
