-- The 2.4 to 2.3 downgrade script must refuse to run in a database
-- that diskquota.prepare_downgrade() has not marked: the cluster cap
-- lives in the launcher's own database, where the script cannot
-- verify it, and an unprepared downgrade would leave the cap armed
-- there, to silently re-arm on a later upgrade back to 2.4.

-- expect fail: refuses transaction blocks under its own name
BEGIN;
SELECT diskquota.prepare_downgrade();
ROLLBACK;
-- expect fail: not prepared
ALTER EXTENSION diskquota UPDATE TO '2.3';
SELECT diskquota.prepare_downgrade();
-- the mark is set
SELECT state FROM diskquota.state;
-- prepared, but the 2.3 library is not preloaded here: the 2.3
-- function bodies refuse to load it and the whole ALTER rolls back
-- atomically, mark included (the error text names library paths, so
-- assert the rollback rather than the message)
DO $$
BEGIN
	EXECUTE 'ALTER EXTENSION diskquota UPDATE TO ''2.3''';
	RAISE WARNING 'downgrade unexpectedly succeeded';
EXCEPTION WHEN OTHERS THEN
	RAISE WARNING 'ALTER rolled back';
END
$$;
SELECT extversion FROM pg_extension WHERE extname = 'diskquota';
SELECT state FROM diskquota.state;
-- cancel the prepared downgrade; the database is ready again
SELECT diskquota.init_table_size_table();
SELECT state FROM diskquota.state;
SELECT diskquota.wait_for_worker_new_epoch();
