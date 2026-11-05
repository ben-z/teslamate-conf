#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_NAMESPACE=teslamate
readonly APP_INGRESS=teslamate-private
readonly TESLAMATE_URL=https://teslamate.benzhang.dev

for task_command in curl jq kubectl python3; do
  command -v "$task_command" >/dev/null || { echo "Missing command: $task_command" >&2; exit 1; }
done
task_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/teslamate-deploy.XXXXXX")"
trap 'rm -rf -- "${task_temp_dir:?}"' EXIT
python3 "$SCRIPT_DIR/render.py" > "$task_temp_dir/application.yaml"

kubectl apply --server-side --dry-run=server --field-manager=teslamate-cd \
  -f "$task_temp_dir/application.yaml" >/dev/null
kubectl apply --server-side --field-manager=teslamate-cd -f "$task_temp_dir/application.yaml"
kubectl -n "$APP_NAMESPACE" rollout status statefulset/database --timeout=15m
for task_deployment in mosquitto gateway; do
  kubectl -n "$APP_NAMESPACE" rollout status "deployment/$task_deployment" --timeout=15m
done
if [[ "$TESLAMATE_MODE" == active ]]; then
  for task_deployment in teslamate grafana; do
    kubectl -n "$APP_NAMESPACE" rollout status "deployment/$task_deployment" --timeout=15m
  done
fi
python3 "$SCRIPT_DIR/verify-images.py" "$task_temp_dir/application.yaml"

task_hostname="${TESLAMATE_URL#https://}"
task_ingress_ready=false
for task_attempt in {1..60}; do
  task_ingress="$(kubectl -n "$APP_NAMESPACE" get "ingress/$APP_INGRESS" -o json)"
  jq -e --arg host "$task_hostname" \
    '.spec.ingressClassName == "tailnet" and [.spec.rules[].host] == [$host]' \
    <<<"$task_ingress" >/dev/null
  if task_private_ip="$(jq -er \
    '[.status.loadBalancer.ingress[]?.ip | select(. != null)] |
     select(length == 1) | .[0] |
     select(test("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\."))' \
    <<<"$task_ingress")"; then
    task_ingress_ready=true
    break
  fi
  echo "Waiting for the Ingress Tailscale address (attempt $task_attempt/60)."
  sleep 5
done
if [[ "$task_ingress_ready" != true ]]; then
  echo "Ingress did not advertise a Tailscale address." >&2
  exit 1
fi
python3 - "$task_private_ip" <<'PYIP'
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
if address not in ipaddress.ip_network("100.64.0.0/10"):
    raise SystemExit(f"Ingress advertised a non-Tailscale IPv4 address: {address}")
PYIP

task_dns_ready=false
for task_attempt in {1..60}; do
  if python3 - "$task_hostname" "$task_private_ip" <<'PYDNS'
import socket
import sys

hostname, expected = sys.argv[1:]
addresses = {item[4][0] for item in socket.getaddrinfo(hostname, 443, socket.AF_UNSPEC, socket.SOCK_STREAM)}
if addresses != {expected}:
    raise SystemExit(f"DNS for {hostname} must resolve only to {expected}, got {sorted(addresses)}")
PYDNS
  then
    task_dns_ready=true
    break
  fi
  echo "Waiting for private DNS (attempt $task_attempt/60)."
  sleep 5
done
if [[ "$task_dns_ready" != true ]]; then
  echo "Private DNS did not converge to the Ingress address." >&2
  exit 1
fi

task_curl=(curl --disable --noproxy "$task_hostname" --connect-timeout 5 --max-time 15
  --retry 6 --retry-delay 5 --retry-all-errors --silent --show-error)
require_private_peer() {
  if [[ "$1" != "$task_private_ip" ]]; then
    echo "Expected HTTPS connection to $task_private_ip, got $1." >&2
    exit 1
  fi
}

task_health_ip="$("${task_curl[@]}" --fail \
  --output "$task_temp_dir/health.json" --write-out '%{remote_ip}' "$TESLAMATE_URL/healthz")"
require_private_peer "$task_health_ip"
jq -e '.status == "ok"' "$task_temp_dir/health.json" >/dev/null

task_version_ip="$("${task_curl[@]}" --fail \
  --output "$task_temp_dir/version.json" --write-out '%{remote_ip}' "$TESLAMATE_URL/api/version")"
require_private_peer "$task_version_ip"
task_live_version="$(jq -er '.version | select(type == "string")' "$task_temp_dir/version.json")"
if [[ "$task_live_version" != "$SOURCE_SHA" ]]; then
  echo "Live application version mismatch: expected $SOURCE_SHA, got $task_live_version." >&2
  exit 1
fi


if [[ "$TESLAMATE_MODE" == prepare ]]; then
  echo "Preparation verified. Cloud logging and scheduled backups remain disabled."
  exit 0
fi

task_frontend_ip="$("${task_curl[@]}" --fail --output /dev/null \
  --write-out '%{remote_ip}' "$TESLAMATE_URL/")"
require_private_peer "$task_frontend_ip"
task_grafana_ip="$("${task_curl[@]}" --fail \
  --output "$task_temp_dir/grafana.json" --write-out '%{remote_ip}' \
  "$TESLAMATE_URL/grafana/api/health")"
require_private_peer "$task_grafana_ip"
jq -e '.database == "ok"' "$task_temp_dir/grafana.json" >/dev/null
echo "Verified release $SOURCE_SHA at $TESLAMATE_URL (TeslaMate and Grafana)."
