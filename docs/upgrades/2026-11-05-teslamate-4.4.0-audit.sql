-- Capture all four variables from the cold pre-upgrade database and reuse them.
-- Only counts, ID aggregates, mileage and payload hashes are output.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\if :{?positions_max_id}
\else
  \echo 'Missing cold positions_max_id'
  SELECT 1 / 0;
\endif
\if :{?charges_max_id}
\else
  \echo 'Missing cold charges_max_id'
  SELECT 1 / 0;
\endif
\if :{?completed_drive_ids}
\else
  \echo 'Missing cold completed_drive_ids'
  SELECT 1 / 0;
\endif
\if :{?completed_charge_ids}
\else
  \echo 'Missing cold completed_charge_ids'
  SELECT 1 / 0;
\endif

BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT 'positions_count|' || count(*) FROM positions
WHERE id <= :'positions_max_id'::bigint;
SELECT 'positions_ids|' || coalesce(sum(id::numeric)::text, 'NULL') FROM positions
WHERE id <= :'positions_max_id'::bigint;
SELECT 'charges_count|' || count(*) FROM charges
WHERE id <= :'charges_max_id'::bigint;
SELECT 'charges_payload|' || md5(coalesce(string_agg(
  md5((to_jsonb(c) - 'charger_phases')::text), '' ORDER BY id), ''))
FROM charges c WHERE id <= :'charges_max_id'::bigint;
SELECT 'normalized_phases|' || md5(coalesce(string_agg(
  md5(id::text || '|' || coalesce(NULLIF(greatest(charger_phases, 0), 0)::text, 'NULL')),
  '' ORDER BY id), ''))
FROM charges WHERE id <= :'charges_max_id'::bigint;
SELECT 'completed_drives_count|' || count(*) FROM drives
WHERE id = ANY(:'completed_drive_ids'::bigint[]);
SELECT 'completed_drives_payload|' || md5(coalesce(string_agg(
  md5(to_jsonb(d)::text), '' ORDER BY id), ''))
FROM drives d WHERE id = ANY(:'completed_drive_ids'::bigint[]);
SELECT 'completed_drives_mileage|' || coalesce(sum(distance::numeric)::text, 'NULL')
FROM drives WHERE id = ANY(:'completed_drive_ids'::bigint[]);
SELECT 'completed_charges_count|' || count(*) FROM charging_processes
WHERE id = ANY(:'completed_charge_ids'::bigint[]);
SELECT 'completed_charges_payload|' || md5(coalesce(string_agg(
  md5((to_jsonb(cp) - 'charge_energy_used')::text), '' ORDER BY id), ''))
FROM charging_processes cp WHERE id = ANY(:'completed_charge_ids'::bigint[]);
SELECT 'completed_charge_costs|' || md5(coalesce(string_agg(
  md5(id::text || '|' || coalesce(cost::text, 'NULL')), '' ORDER BY id), ''))
FROM charging_processes WHERE id = ANY(:'completed_charge_ids'::bigint[]);
COMMIT;
