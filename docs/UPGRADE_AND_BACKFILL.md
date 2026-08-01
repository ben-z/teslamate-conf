# TeslaMate Upgrade and Mileage Backfill

This runbook documents the August 2026 upgrade of this rootful Docker deployment and the recovery procedure used after a Tesla API outage left mileage dashboards stale.

## Why the deployment was upgraded

The deployment was running TeslaMate 2.1.1 when Tesla's Owner API began returning HTTP 403 responses on June 12, 2026. Streaming positions continued to arrive while normal vehicle-data polling failed. As a result, TeslaMate could not observe the Park transitions needed to close drives, and Grafana's mileage dashboards stopped advancing even though recent odometer samples were still present.

The upstream incident is documented in [teslamate-org/teslamate#5384](https://github.com/teslamate-org/teslamate/issues/5384). [TeslaMate 4.0.0](https://github.com/teslamate-org/teslamate/releases/tag/v4.0.0) fixed the Owner API 403 problem, and [4.0.1](https://github.com/teslamate-org/teslamate/releases/tag/v4.0.1) added a refresh-token fix. This repository therefore pins both TeslaMate and its matching Grafana image to 4.0.1 by tag and digest.

The database remained on PostgreSQL 17.5. TeslaMate 4.0.1 reports that the PostgreSQL 17.x series is compatible.

## Upgrade procedure

Run commands from the repository root. Docker is rootful on this host, so all Docker commands use `sudo`.

### 1. Review and validate the change

Read the release notes for every skipped TeslaMate version. Update the TeslaMate and Grafana image tags and digests together, then validate the rendered Compose configuration:

```bash
sudo docker compose config --quiet
git diff --check
git diff -- docker-compose.yml
```

Do not use a floating `latest` tag. Digest pins make the deployed artifact reproducible.

### 2. Create a verified database backup

Create the dump in `tmp/`, which is ignored by Git. The command runs `pg_dump` inside the database container while writing the archive on the host:

```bash
mkdir -p tmp
chmod 700 tmp
backup_path="tmp/teslamate-pre-upgrade-$(date -u +%Y%m%d-%H%M%S).dump"
umask 077
sudo docker compose exec -T database sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$backup_path"
```

Verify the archive before changing containers:

```bash
stat -c '%n %s bytes mode=%a' "$backup_path"
sha256sum "$backup_path"
sudo docker compose exec -T database pg_restore --list < "$backup_path" >/dev/null
```

The file mode should be `600`, `pg_dump` must exit successfully, and `pg_restore --list` must be able to read the complete custom-format archive. Record the path and SHA-256 digest.

For a major or high-risk upgrade, also prove the backup by restoring it into an isolated database as described below.

### 3. Pull and deploy

```bash
sudo docker compose pull teslamate grafana
sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs --since=10m --no-color teslamate grafana
```

Confirm that TeslaMate reports the expected version, migrations complete, PostgreSQL is compatible, token refresh succeeds, MQTT connects, and both vehicle loggers start.

Check the local endpoints:

```bash
curl -fsS -o /dev/null -w 'TeslaMate %{http_code}\n' http://127.0.0.1:4000/
curl -fsS -o /dev/null -w 'Grafana %{http_code}\n' http://127.0.0.1:3001/
```

TeslaMate should return `200`. Grafana normally returns a login redirect.

## Diagnosing stale mileage

Grafana's mileage dashboards use completed rows in `drives`, especially `start_km` and `end_km`. Recent raw positions do not appear in mileage totals while their drive remains incomplete.

Find incomplete drives without displaying vehicle locations:

```sql
SELECT d.id,
       d.car_id,
       d.start_date,
       d.end_date,
       count(p.id) AS positions,
       min(p.date) AS first_position,
       max(p.date) AS last_position,
       min(p.odometer) AS minimum_odometer,
       max(p.odometer) AS maximum_odometer
FROM drives d
LEFT JOIN positions p ON p.drive_id = d.id
WHERE d.end_date IS NULL
GROUP BY d.id, d.car_id, d.start_date, d.end_date
ORDER BY d.start_date;
```

Also confirm whether raw telemetry is current:

```sql
SELECT car_id, max(date) AS latest_position, max(odometer) AS latest_odometer
FROM positions
GROUP BY car_id
ORDER BY car_id;
```

If one ordinary drive is incomplete, follow TeslaMate's [manual data-repair documentation](https://github.com/teslamate-org/teslamate/blob/v4.0.1/website/docs/maintenance/manually_fixing_data.mdx) after taking a backup.

Do **not** directly close a drive containing days or weeks of positions. [`TeslaMate.Log.close_drive/2`](https://github.com/teslamate-org/teslamate/blob/v4.0.1/lib/teslamate/log.ex) aggregates every position with that `drive_id`; closing a multi-week record without segmenting it first creates one enormous, incorrect drive.

## Backfilling a multi-drive outage

Park/Drive transitions are not stored in `positions`. If polling failed while streaming continued, exact historical trip boundaries cannot be recovered. Odometer-based mileage is reliable for the surviving samples, but reconstructed trip boundaries must be treated as an evidence-based approximation.

Never experiment on production. Build and validate an incident-specific repair against a restored clone first.

### 1. Stop writes and take a fresh backup

For the final production repair, stop only the TeslaMate logger. PostgreSQL, Grafana, and MQTT may remain running:

```bash
sudo docker compose stop teslamate
```

Take and verify another custom-format dump using the backup procedure above. This is the cold, immediately-pre-repair rollback point.

### 2. Restore an isolated test database

Choose a unique, explicit name and verify that it does not exist before creating it:

```bash
test_db="teslamate_repair_test_$(date -u +%Y%m%d)"
sudo docker compose exec -T database sh -c \
  'psql -U "$POSTGRES_USER" -d postgres -Atc "SELECT datname FROM pg_database"'
sudo docker compose exec -T database sh -c \
  "createdb -U \"\$POSTGRES_USER\" -T template0 '$test_db'"
sudo docker compose exec -T database sh -c \
  "pg_restore -U \"\$POSTGRES_USER\" -d '$test_db' --exit-on-error" \
  < "$backup_path"
```

Compare row counts, maximum IDs, affected position counts, and schema migrations between production and the clone before testing any repair.

### 3. Derive and validate boundaries

For the June 2026 incident, consecutive positions were considered a new candidate segment when either:

1. the timestamp gap exceeded TeslaMate's 15-minute drive timeout; or
2. the gap exceeded 30 seconds, the prior sample reported zero speed, the odometer changed by no more than 0.02 km, and the endpoints were within 20 metres.

The second rule recognizes a parked vehicle while tolerating GPS and odometer noise. Before using it, compare it with known completed-drive boundaries and known within-drive gaps from the same cars. In this deployment it produced one stationary split across 2.16 million historical within-drive gaps; looser thresholds sometimes split genuine movement.

Each candidate segment must have at least two positions and at least 0.01 km of forward odometer movement to become a drive. Preserve zero-distance samples as unassociated raw positions; do not delete them.

This rule is specific to the observed sampling behavior. Revalidate it for any future incident rather than copying the thresholds blindly.

### 4. Build a guarded transaction

The incident-specific SQL should:

1. require an explicit expected database name and abort on a mismatch;
2. lock `drives` and `positions` against concurrent writes;
3. assert the exact source drive IDs and position counts;
4. calculate candidate segments in temporary tables;
5. assert the expected candidate, valid-drive, and zero-distance counts;
6. insert new drive rows with IDs increasing globally by `start_date`, then reassign every affected position exactly once;
7. reproduce TeslaMate's `close_drive/2` aggregates, including dates, odometer distance, duration, ranges, temperatures, speed, power, elevation, position IDs, and geofences;
8. assert raw-position counts, target mappings, mileage totals, chronology, and foreign-key integrity; and
9. commit only if every assertion succeeds.

Keep the transaction wrapped in `BEGIN`/`COMMIT`, use `psql` with `ON_ERROR_STOP`, and make every failed invariant raise an exception so PostgreSQL rolls back the whole repair.

Drive IDs are ordering data in practice. The Grafana Drives dashboard orders its table by `drive_id DESC`, and other TeslaMate dashboards use adjacent IDs to infer preceding or following drives. Do not rely on unspecified `UPDATE` or `INSERT` row order when allocating IDs, and do not allocate separate chronological sequences per car. Assign the recovered range in one global `ORDER BY start_date,id` sequence, preserving any newer natural drives outside that range.

### 5. Prove the repair on the clone

Validate at least these invariants:

- the total `positions` count is unchanged;
- every source position maps to its intended reconstructed drive or an explicitly retained zero-distance fragment;
- all reconstructed drives have start/end dates and positions;
- all reconstructed distances are at least 0.01 km;
- reconstructed drives do not overlap for the same car;
- reconstructed IDs have no chronological inversions when ordered numerically;
- no drive-to-position or position-to-drive foreign keys are broken;
- the sum of `drives.distance` matches the sum of segment end-odometer minus start-odometer; and
- no unintended incomplete drives remain.

Check ID chronology explicitly:

```sql
SELECT count(*) AS chronological_inversions
FROM (
  SELECT id,
         start_date,
         lag(start_date) OVER (ORDER BY id) AS previous_start
  FROM drives
  WHERE id BETWEEN :first_reconstructed_id AND :last_reconstructed_id
) ordered
WHERE start_date < previous_start;
```

The result must be zero. Also compare the newest drive for each car using both `ORDER BY start_date DESC` and `ORDER BY id DESC`; they must identify the same drive.

Review per-car drive counts, mileage, average duration, maximum duration, and days containing raw samples but no reconstructed mileage. Inspect aggregate results only; do not put coordinates, VINs, tokens, or credentials in logs or Git.

### 6. Apply the identical transaction to production

With TeslaMate still stopped, execute the exact SQL proven on the clone. Pass the production database name separately so the script's database guard remains active:

```bash
sudo docker compose exec -T database psql \
  -U teslamate -d teslamate \
  -v expected_database=teslamate \
  -P pager=off \
  < reviewed-backfill.sql
```

Do not edit the repair between the clone run and the production run. Refresh planner statistics after a large reassignment:

```bash
sudo docker compose exec -T database psql -U teslamate -d teslamate \
  -v ON_ERROR_STOP=1 -c 'ANALYZE drives;' -c 'ANALYZE positions;'
```

Run the complete validation suite again before restarting TeslaMate.

### 7. Restart and monitor TeslaMate

```bash
sudo docker compose start teslamate
sudo docker compose logs --since=5m --no-color teslamate
```

TeslaMate may find reconstructed drives without addresses and run its own repair worker. This is expected after segmentation. Monitor its progress without querying or logging coordinates:

```sql
SELECT count(*) FILTER (
         WHERE start_address_id IS NOT NULL AND end_address_id IS NOT NULL
       ) AS complete,
       count(*) FILTER (
         WHERE start_address_id IS NULL OR end_address_id IS NULL
       ) AS remaining
FROM drives
WHERE id IN (/* exact reconstructed drive IDs */);
```

The address pass is normally network-rate-limited by reverse-geocoding calls, not CPU- or disk-bound. Watch logs for `Repairing drive`, successful reverse lookups, `OK`, warnings, and HTTP failures. Do not interrupt it merely because it is slow.

After completion, rerun all database checks, verify the HTTP endpoints and containers, and take a verified post-repair dump.

### Correcting non-chronological reconstructed IDs

If an earlier reconstruction assigned valid drives non-chronological IDs, do not change timestamps or rebuild the drives. Remap only the known reconstructed ID range in an isolated clone, then apply the identical guarded transaction to production.

The remap must:

1. snapshot every affected drive payload excluding `id` and every affected position ID;
2. map the reconstructed range to a global `row_number() OVER (ORDER BY start_date,id)` sequence;
3. move drives and `positions.drive_id` references through collision-free temporary IDs;
4. leave newer natural drive IDs and the `trips_id_seq` value unchanged;
5. verify every drive payload is identical except for `id`;
6. verify every affected position points to its intended new ID;
7. verify mileage, row counts, addresses, endpoints, foreign keys, and outside-range drives are unchanged; and
8. verify zero chronological inversions before commit.

On a large positions table, the `ON DELETE SET NULL` foreign-key trigger can be slow if `positions.drive_id` has only a BRIN index. A transaction-scoped B-tree index on `positions(drive_id)` makes the remap's equality lookups efficient; drop that temporary index before commit so the production schema remains unchanged.

Renumbering changes the meaning of old bookmarked drive-detail URLs because those URLs contain `drive_id`. Refresh Grafana after the remap and treat pre-remap drive-detail bookmarks as stale.

### 8. Clean up safely

Only after the pre-repair and post-repair archives have been verified should the disposable clone be removed. Resolve the exact name and confirm that it has zero active connections before running `dropdb`. The clone remains reproducible from the verified pre-repair archive.

## August 2026 recovery result

The production recovery reconstructed 340 completed drives from 964,741 affected raw positions. It retained every raw position, left 2,914 zero-distance samples unassociated, produced no overlapping drives or broken references, and restored 4,208.434561 km of observed odometer mileage across both cars. TeslaMate's built-in worker subsequently completed address enrichment for all reconstructed drives.

A follow-up validation found that the initial SQL had assigned some new IDs in unspecified update order. Although drive contents and mileage were correct, Grafana displayed an older drive first because it sorts the Drives table by ID. A clone-tested follow-up remapped 339 reconstructed drives into global chronological order, changing 338 IDs while preserving all drive fields and 959,387 position links. Post-remap validation found zero chronological inversions, broken references, missing addresses, or mileage changes.

Verified pre-repair and post-repair dumps are stored locally under `tmp/` and are intentionally excluded from Git.
