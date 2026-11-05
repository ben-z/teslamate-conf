#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  echo "Usage: $0 compose OUTPUT.dump | kubernetes CONTEXT OUTPUT.dump" >&2
  exit 1
}
[[ $# -ge 2 ]] || usage
task_target="$1"
case "$task_target" in
  compose)
    [[ $# == 2 ]] || usage
    task_output="$2"
    task_exec=(sudo -n docker compose exec -T database)
    task_user='"$POSTGRES_USER"'
    ;;
  kubernetes)
    [[ $# == 3 ]] || usage
    task_output="$3"
    task_exec=(kubectl --context "$2" -n teslamate exec -i statefulset/database --)
    task_user='"$(cat /mnt/secrets-store/database-user)"'
    ;;
  *) usage ;;
esac
[[ ! -e "$task_output" && ! -e "$task_output.sha256" ]] || {
  echo "Refusing to overwrite an existing backup or checksum." >&2
  exit 1
}
mkdir -p -- "$(dirname -- "$task_output")"
task_partial="$(mktemp "$task_output.partial.XXXXXX")"
trap 'rm -f -- "${task_partial:?}"' EXIT
"${task_exec[@]}" sh -ec "pg_dump -U $task_user -d teslamate -Fc" > "$task_partial"
[[ -s "$task_partial" ]]
"${task_exec[@]}" pg_restore --list < "$task_partial" >/dev/null
# A hard link publishes the completed archive without overwriting another run.
ln -- "$task_partial" "$task_output"
(set -o noclobber; sha256sum -- "$task_output" > "$task_output.sha256")
sha256sum --check "$task_output.sha256"
echo "Archive created with mode 600: $task_output"
