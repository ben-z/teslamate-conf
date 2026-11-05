#!/usr/bin/env bash
set -euo pipefail

check_permission() {
  local task_expected="$1"
  shift
  local task_result task_status=0
  task_result="$(kubectl auth can-i "$@")" || task_status=$?
  if [[ "$task_result" != "$task_expected" ]] || [[ "$task_status" -gt 1 ]]; then
    echo "Unexpected authorization result for: kubectl auth can-i $* (result=$task_result, exit=$task_status)" >&2
    exit 1
  fi
  echo "Verified $task_expected: $*"
}

for task_resource in serviceaccounts services persistentvolumeclaims configmaps \
  deployments.apps statefulsets.apps cronjobs.batch ingresses.networking.k8s.io \
  networkpolicies.networking.k8s.io secretproviderclasses.secrets-store.csi.x-k8s.io; do
  check_permission yes create "$task_resource" -n teslamate
done
for task_resource in pods pods/log events replicasets.apps; do
  check_permission yes get "$task_resource" -n teslamate
done
for task_verb in get create patch delete; do
  check_permission no "$task_verb" secrets -n teslamate
done
check_permission no create pods/exec -n teslamate
check_permission no create namespaces
check_permission no create clusterrolebindings.rbac.authorization.k8s.io
check_permission no create deployments.apps -n default
check_permission no get pods -n kube-system
check_permission no delete persistentvolumeclaims -n teslamate
echo 'Production OIDC login and namespace permission boundaries verified without deployment.'
