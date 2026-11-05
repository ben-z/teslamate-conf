# TeslaMate

Configuration for this deployment: TeslaMate 4.0.1, its matching Grafana dashboards, PostgreSQL 17.5, and Mosquitto 2.0.21. Images are pinned by digest. Prometheus belongs to the host's separate observability stack.

## Cloud deployment

The application follows the [Unicorns satellite deployment contract](https://github.com/unicorns/infra/blob/main/docs/satellite-app-deployment.md) on `unicorns-aks`, namespace `teslamate`.

| Service | Private address |
| --- | --- |
| TeslaMate | https://teslamate.benzhang.dev/ |
| Grafana | https://teslamate.benzhang.dev/grafana/ |
| Release identifier | https://teslamate.benzhang.dev/api/version |

These are the intended cloud addresses; follow the [migration runbook](docs/CLOUD_MIGRATION.md) to register, restore, and activate them. Tailscale supplies private access and the platform handles TLS. Database and MQTT Services stay inside the cluster; MQTT requires authentication.

Application configuration lives in `deploy/`. Actions checks changes, publishes native AMD64/ARM64 gateway and backup images, and deploys with GitHub OIDC and namespace-scoped RBAC. Runtime credentials come from a dedicated Key Vault through AKS workload identity.

Bootstrap initializes `TESLAMATE_MODE=prepare`: PostgreSQL, MQTT, and the gateway start, while TeslaMate, Grafana, and scheduled backups stay off. Enable `active` only after stopping the old logger and verifying the restored database.

## Existing Compose deployment

Use Docker Engine and Compose v2. Run these commands from the repository root. The existing host uses rootful Docker:

```sh
sudo docker compose config --quiet
sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs --since=10m teslamate
```

For a new installation, copy `.env.example` to `.env` and replace every placeholder; generate an encryption key with `openssl rand -hex 32`. For this existing installation, preserve the current `.env`, especially `TESLAMATE_ENCRYPTION_KEY`, which decrypts the stored Tesla tokens.

TeslaMate is at http://127.0.0.1:4000/ and Grafana is at http://localhost:3001/. Compose publishes Grafana on all host interfaces. Change a new Grafana installation's initial `admin`/`admin` password after signing in. See [upstream installation instructions](https://docs.teslamate.org/docs/installation/docker/) for Tesla authentication.

Compose persists PostgreSQL in `data/teslamate-db`, Grafana in `data/grafana`, MQTT files in `data/mosquitto-*`, and imports in `import/`. These paths and `.env` are ignored by Git. Never run the local and cloud loggers for the same account together.

## Backups and maintenance

Create a logical backup with mode 600, archive verification, and a SHA-256 checksum:

```sh
scripts/backup.sh compose "tmp/teslamate-$(date -u +%Y%m%dT%H%M%SZ).dump"
# On an operator host:
scripts/backup.sh kubernetes YOUR_CONTEXT "tmp/teslamate-$(date -u +%Y%m%dT%H%M%SZ).dump"
```

Copy verified archives to an independent location. Also preserve the encryption key and Grafana files. Copying a running PostgreSQL data directory is not a logical backup. Cloud PostgreSQL backups run daily into a private Blob container with 30-day retention; the migration runbook explains coverage and recovery.

The [2026-08-01 upgrade and mileage backfill runbook](docs/upgrades/2026-08-01-teslamate-4.0.1-mileage-backfill.md) records the earlier upgrade and recovery. Infrastructure migration keeps those application versions unchanged.

## Checks

```sh
python3 -m pip install -r requirements-dev.txt
scripts/check.sh
# With access to the Docker daemon; uses isolated temporary containers:
scripts/smoke-gateway.sh
scripts/smoke-services.sh
```

Pull requests run the checks and build both custom containers. Production rollout verifies every workload image digest, private DNS, trusted HTTPS, the source commit endpoint, TeslaMate, and Grafana health. Operator access can be checked independently with the workflow's `verify_access_only` input.
