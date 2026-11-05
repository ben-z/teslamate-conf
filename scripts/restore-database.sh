#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $# == 2 ]] || { echo "Usage: $0 CONTEXT BACKUP.dump" >&2; exit 1; }
task_kubectl=(kubectl --context "$1" -n teslamate)
task_backup="$2"
sha256sum --check --status "$task_backup.sha256"
for task_app in teslamate grafana; do
  task_replicas="$("${task_kubectl[@]}" get "deployment/$task_app" -o jsonpath='{.spec.replicas}')"
  [[ "$task_replicas" == 0 ]] || { echo "Stop cloud $task_app before restoring." >&2; exit 1; }
  "${task_kubectl[@]}" wait --for=delete pod -l "app=$task_app" --timeout=5m
done
task_exec=("${task_kubectl[@]}" exec -i statefulset/database --)
task_tables="$("${task_exec[@]}" sh -ec \
  'psql -U "$(cat /mnt/secrets-store/database-user)" -d teslamate -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema = '\''public'\'' AND table_type = '\''BASE TABLE'\''"')"
[[ "$task_tables" == 0 ]] || { echo 'Target database is not empty; refusing to restore.' >&2; exit 1; }
"${task_exec[@]}" pg_restore --list < "$task_backup" >/dev/null
"${task_exec[@]}" sh -ec \
  'pg_restore -U "$(cat /mnt/secrets-store/database-user)" -d teslamate --single-transaction --exit-on-error --no-owner --no-privileges' \
  < "$task_backup"
echo 'Database restored atomically. Compare database-summary.sql results before enabling logging.'
