\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT format('SELECT %L || ''|'' || count(*) FROM %I.%I;',
              table_name, table_schema, table_name)
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name
\gexec
SELECT format('SELECT %L || ''|'' || last_value || ''|'' || is_called FROM %I.%I;',
              sequencename, schemaname, sequencename)
FROM pg_sequences
WHERE schemaname = 'public'
ORDER BY sequencename
\gexec
SELECT 'latest_schema_migration|' || max(version) FROM schema_migrations;
COMMIT;
