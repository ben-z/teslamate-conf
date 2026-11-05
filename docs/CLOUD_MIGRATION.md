# Migrate Compose to Unicorns AKS

Follow the [satellite deployment contract](https://github.com/unicorns/infra/blob/main/docs/satellite-app-deployment.md). The app owns manifests and releases; the operator owns registration. Keep Compose running until cloud preparation succeeds, then stop source writers before the final dump. Never run both loggers together.

## Deployment contract

| Setting | Value |
| --- | --- |
| Repository / protected branch | `ben-z/teslamate-conf` / `main` |
| Cluster / resource group | `unicorns-aks` / `unicorns-aks-rg` |
| Namespace / workload ServiceAccount | `teslamate` / `teslamate` |
| Private ingress / host | `tailnet` / `teslamate.benzhang.dev` |
| Grafana subpath | `/grafana/` |
| GitHub environment / OIDC subject | `production` / `repo:ben-z/teslamate-conf:environment:production` |
| Tailscale CI tag | `tag:unicorns-private-ci` |

The source-built gateway embeds its full commit SHA at `/api/version` and proxies TeslaMate HTTP/WebSockets. The same Ingress sends `/grafana` directly to Grafana, which serves that subpath. Platform wildcard DNS and TLS provide private HTTPS. No public application record, load balancer, certificate Secret, or ingress annotation is needed.

PostgreSQL uses a retained 20 GiB claim. Grafana, MQTT, and imports each use 1 GiB claims, with `managed-csi` and `ReadWriteOnce`. Azure disk billing rounds capacity to disk tiers. Explicitly deleting a claim or namespace can delete disks; StatefulSet claim retention does not prevent that.

Pods run as non-root, with RuntimeDefault seccomp, no privilege escalation, and all capabilities dropped. Services are ClusterIP only; PostgreSQL and MQTT require credentials. NetworkPolicies require an enforcing CNI. The operator reported `networkPolicy: none` on this cluster, so the supplied policies do **not** currently isolate traffic.

Pods select application pools and tolerate/prefer Spot. This single-instance deployment can pause collection during evictions, capacity shortages, and disk reattachment. Disks and off-host backups preserve history; this is not a highly available database.

## 1. Operator registration

Use an operator workstation with Azure deployment/role-assignment rights, AKS administrator access, GitHub repository administration, and Tailscale federation permissions. Do not copy Azure administrator credentials or a cluster-admin kubeconfig to `cn65`.

`deploy/bootstrap/main.bicep` creates the deployment and runtime identities, dedicated Key Vault, backup storage account/container, and scoped Azure assignments. Runtime gets Secrets User on this vault and Blob Data Contributor on this container. The operator gets vault Secrets Officer and container Blob Data Reader. The deployer gets AKS Cluster User plus the namespace Role; it cannot access Secrets, exec into Pods, delete PVCs, or administer other namespaces.

`namespace-rbac.yaml` labels the namespace `unicorns.dev/satellite=true` and enables restricted Pod Security admission before workloads are handed to the deployer. Regular releases do not manage namespaces or RBAC.

With `az`, `gh`, `jq`, Python 3, and Bicep installed, provide a temporary Tailscale operator token through a secure environment mechanism:

```sh
export TAILSCALE_CI_TAG=tag:unicorns-private-ci
# Supply TAILSCALE_API_TOKEN without shell tracing or putting it in Git.
az bicep install
deploy/bootstrap/bootstrap.sh
```

The helper registers `auth_keys` trust for the exact production subject, immutable repository/owner IDs, and existing shared CI tag. It does not change tailnet policy. Revoke the temporary token afterward. An operator can register Tailscale through its authenticated admin UI and execute the Azure/namespace/environment steps independently.

Non-secret `production` variables are `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_AKS_CLUSTER_NAME`, `TESLAMATE_KEY_VAULT_NAME`, `TESLAMATE_SECRET_IDENTITY_CLIENT_ID`, `TESLAMATE_BACKUP_ACCOUNT`, `TESLAMATE_MODE`, `TAILSCALE_CLIENT_ID`, `TAILSCALE_AUDIENCE`, and `TAILSCALE_CI_TAG`.

Initialize `TESLAMATE_MODE=prepare` and allow only `main` in the environment. Bootstrap preserves an existing valid mode. The two GHCR packages, `ben-z/teslamate-gateway` and `ben-z/teslamate-backup`, must be readable by the cluster: make them public, or have the operator supply read-only image-pull credentials. CI cannot create Secrets.

After the workflow is on `main`, prove Azure OIDC and namespace allows/denies independently:

```sh
gh workflow run deploy.yml --repo ben-z/teslamate-conf --ref main -f verify_access_only=true
```

This job does not join Tailscale, build images, deploy workloads, or read runtime secrets. Normal releases join Tailscale only to verify the private application's HTTPS endpoint.

## 2. Transfer credentials directly

| Vault secret | Source |
| --- | --- |
| `teslamate-encryption-key` | Existing Compose encryption key, unchanged |
| `teslamate-database-user` | Existing database username, unchanged |
| `teslamate-database-password` | Existing database password, unchanged |
| `teslamate-grafana-admin-password` | Generated initial password; a restored Grafana database retains its existing login |
| `teslamate-mqtt-password` | Generated broker password |

Run on the signed-in operator host, with shell tracing off:

```sh
set -o pipefail
ssh ben@cn65 'cd /home/ben/Projects/teslamate-conf && docker compose config --format json' \
  | python3 deploy/bootstrap/populate-secrets.py --compose-stdin --vault-name YOUR_VAULT
```

Do not save, print, or paste the Compose JSON. The helper uses private temporary files for Key Vault upload and removes them on exit. It refuses different existing encryption/database credentials and preserves generated passwords on reruns. Secret values never enter Actions or Kubernetes Secret objects. Preserve the encryption key independently; a database dump cannot decrypt tokens by itself.

## 3. Prepare the cloud

Merge the reviewed migration PR with mode `prepare`. Actions checks source, publishes native AMD64/ARM64 images by digest, validates admission, waits for PostgreSQL/broker/gateway, checks all workload images/settings, and verifies private DNS, trusted TLS, and the exact source SHA. TeslaMate and Grafana have zero replicas; the backup CronJob is suspended.

On the operator workstation use an explicit context throughout:

```sh
task_context=YOUR_OPERATOR_CONTEXT
kubectl --context "$task_context" -n teslamate get pods,pvc,deploy,cronjob,ingress
```

Continue only when PostgreSQL/MQTT/gateway are ready and both application replica counts are zero. Grafana/import PVCs can remain Pending under `WaitForFirstConsumer` until the restore Pod runs.

## 4. Stop source writes and back up

Run on `cn65` once cloud preparation passes. Leave PostgreSQL and MQTT running:

```sh
sudo docker compose stop teslamate grafana
mkdir -p tmp
chmod 700 tmp
umask 077
task_backup="tmp/teslamate-cutover-$(date -u +%Y%m%dT%H%M%SZ).dump"
scripts/backup.sh compose "$task_backup"
sudo docker compose exec -T database sh -ec \
  'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q' \
  < scripts/database-summary.sql > "$task_backup.summary"
sudo tar -C data/grafana -cf - . > tmp/grafana-cutover.tar
sha256sum tmp/grafana-cutover.tar > tmp/grafana-cutover.tar.sha256
```

Privately transfer the archive, checksum, summary, and Grafana tar/checksum to the operator workstation with mode 600. Keep relative paths from checksum files consistent. Archive/transfer any nonempty `import/` directory too. The original no-auth MQTT configuration does not enable persistence, so TeslaMate can republish state to the new broker. Retain source data/containers. Do not restart the source logger.

## 5. Restore and compare

On the operator workstation:

```sh
scripts/restore-database.sh "$task_context" "$task_backup"
kubectl --context "$task_context" -n teslamate exec -i statefulset/database -- sh -ec \
  'exec psql -U "$(cat /mnt/secrets-store/database-user)" -d teslamate -q' \
  < scripts/database-summary.sql > "$task_backup.cloud-summary"
diff -u "$task_backup.summary" "$task_backup.cloud-summary"
```

The script checks the SHA-256, stopped target applications, empty public schema, and archive table of contents before an atomic `pg_restore --single-transaction --exit-on-error --no-owner --no-privileges`. It never cleans/drops an existing target. Failed restores roll back; a nonempty target needs a separately reviewed recovery procedure.

The summary compares all public table counts, sequence values/`is_called`, and latest migration without exposing locations or tokens. Require an empty diff before activation.

Restore Grafana with both applications still stopped:

```sh
sha256sum --check tmp/grafana-cutover.tar.sha256
kubectl --context "$task_context" apply -f deploy/kubernetes/restore-files.yaml
kubectl --context "$task_context" -n teslamate wait --for=condition=Ready pod/file-restore --timeout=15m
set -o pipefail
python3 deploy/strip-tar-root.py tmp/grafana-cutover.tar \
  | kubectl --context "$task_context" -n teslamate exec -i file-restore -- \
      tar -xf - --no-same-owner -C /restore/grafana
# If needed, extract the import archive into /restore/import similarly.
kubectl --context "$task_context" -n teslamate delete pod/file-restore --wait
```

The temporary Pod runs without root or secrets. The helper omits only the archive's root-directory header, preserving all file contents and the original archive. This avoids changing metadata on the root-owned CSI mountpoint while extracting as Grafana's UID. Remove the Pod before starting the PVC consumers. Never copy a running Grafana SQLite database.

## 6. Activate and verify

Once summaries match and Grafana files are restored:

```sh
gh variable set TESLAMATE_MODE --repo ben-z/teslamate-conf --env production --body active
gh workflow run deploy.yml --repo ben-z/teslamate-conf --ref main
```

The workflow verifies images/version, TeslaMate HTTP, and Grafana database health over private trusted HTTPS. Set TeslaMate Settings URLs to `https://teslamate.benzhang.dev` and `https://teslamate.benzhang.dev/grafana`. Confirm token decryption/refresh, MQTT authentication, both vehicle loggers, recent telemetry, and historical dashboards. Review logs privately because they can contain vehicle information.

Leave source applications stopped. Their `always` restart policy could restart them after a host/Docker reboot; after cloud checks pass run `sudo docker update --restart=no teslamate-conf-teslamate-1 teslamate-conf-grafana-1` and disable any host automation that runs `docker compose up -d`. Keep the source database and cold archives for rollback.

## Backups and rollback

The active-only CronJob runs at 11:00 UTC daily. It creates a custom-format dump, reads its table of contents, uploads with workload identity, checks per-block integrity, and verifies stored size/SHA-256 metadata. Storage disallows shared keys/public blobs. Backups expire after 30 days, with 14-day soft deletion. No storage keys or SAS tokens are used.

Scheduled archives cover PostgreSQL history/settings/encrypted tokens. Preserve the encryption key separately. Grafana SQLite users/preferences/custom dashboards and original import files need separate archives after changes. Monitor failed/missed Jobs and periodically prove a downloaded dump with an isolated PostgreSQL 17 restore; table-of-contents checks alone do not prove a full restore.

Before cloud logging starts, rollback means keeping cloud mode at prepare, waiting for cloud application Pods to disappear, then starting original Compose services. After cloud logging starts, stop cloud writers and take fresh verified database/Grafana backups, then restore into separately prepared source storage. Restarting the stale cold database would lose new cloud data. Never run both loggers concurrently.

Custom-image rollback uses the protected `main` workflow with both previously approved image digests and their full source SHA. It verifies revision labels for both architectures and the live version endpoint, retaining current private manifests and mode. It rolls back gateway/backup images only. TeslaMate/PostgreSQL version changes and database migrations require their own upgrade/restore plan.
