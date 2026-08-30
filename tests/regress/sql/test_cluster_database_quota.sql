-- Test cluster-wide and per-database disk quota
CREATE SCHEMA cdqschema;
SET search_path TO cdqschema;
CREATE TABLE cdq_t (i INT, t TEXT) DISTRIBUTED BY (i);

-- cap the whole cluster; an unmonitored database triggers the
-- blind-spot warning (list normalized by init_file matchsubs)
CREATE DATABASE cdq_unmonitored;
SELECT diskquota.set_cluster_quota('10 MB');
DROP DATABASE cdq_unmonitored;
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.cluster_quota_limit_mb();
-- starts under the cap, so the load is allowed to complete (soft limit)
INSERT INTO cdq_t SELECT g, repeat('x', 1000) FROM generate_series(1, 20000) g;
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail: cluster cap exceeded
INSERT INTO cdq_t VALUES (1, 'x');
-- reads still work
SELECT count(*) FROM cdq_t;

-- === launcher exemption: the cap must not wedge its own controls ===
-- raising the quota while over the cap must work: the launcher's
-- write to its global config table is exempt from the cap it manages
-- (silence the unmonitored-databases warning here: whether it fires
-- depends on which other databases exist in the cluster, and it has
-- its own deterministic coverage in this test)
SET client_min_messages = error;
SELECT diskquota.set_cluster_quota('1 GB');
RESET client_min_messages;
SELECT diskquota.cluster_quota_limit_mb();
SELECT diskquota.wait_for_worker_new_epoch();
-- writes resume under the raised cap
INSERT INTO cdqschema.cdq_t VALUES (1, 'x');
-- lower it back under current usage; the cap bites again
SET client_min_messages = error;
SELECT diskquota.set_cluster_quota('10 MB');
RESET client_min_messages;
SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail: over the lowered cap again
INSERT INTO cdqschema.cdq_t VALUES (1, 'x');
-- a new database can start being monitored while the cluster is over
-- the cap: CREATE EXTENSION goes through the launcher's bookkeeping
CREATE DATABASE cdq_join;
\c cdq_join
-- unmonitored database while the cluster is over its cap: it is not
-- counted in the cluster total, so it is not blocked by it either
CREATE TABLE join_t (i INT, t TEXT) DISTRIBUTED BY (i);
INSERT INTO join_t VALUES (1, 'x');
DROP TABLE join_t;
CREATE EXTENSION diskquota;
SELECT diskquota.wait_for_worker_new_epoch();
DROP EXTENSION diskquota;
\c contrib_regression
SET search_path TO cdqschema;
SELECT diskquota.wait_for_worker_new_epoch();
DROP DATABASE cdq_join;

-- delete the cluster quota; writes resume
SELECT diskquota.set_cluster_quota('-1');
SELECT diskquota.wait_for_worker_new_epoch();
INSERT INTO cdq_t VALUES (1, 'x');

-- cap this database only
SELECT diskquota.set_database_quota(current_database()::text, '10 MB');
SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail: database usage already exceeds the cap
INSERT INTO cdq_t VALUES (2, 'x');
-- expect fail: another database's quota cannot be set from here
SELECT diskquota.set_database_quota('template1', '10 MB');
-- delete the database quota; writes resume
SELECT diskquota.set_database_quota(current_database()::text, '-1');
SELECT diskquota.wait_for_worker_new_epoch();
INSERT INTO cdq_t VALUES (3, 'x');

DROP TABLE cdq_t;

-- === the blind spot, end to end ===
-- a database without the extension is invisible to the cluster cap
-- until the extension is created and initialized there
CREATE TABLE cdqschema.cdq_t2 (i INT, t TEXT) DISTRIBUTED BY (i);
CREATE DATABASE cdq_blind;
-- warning again: cdq_blind is unmonitored (list normalized by matchsubs)
SELECT diskquota.set_cluster_quota('10 MB');
SELECT diskquota.wait_for_worker_new_epoch();
\c cdq_blind
CREATE TABLE blind_t (i INT, t TEXT) DISTRIBUTED BY (i);
-- ~15 MB, well over the 10 MB cap: succeeds, the database is invisible
INSERT INTO blind_t SELECT g, repeat('x', 1000) FROM generate_series(1, 15000) g;
\c contrib_regression
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.wait_for_worker_new_epoch();
-- the unmonitored load does not show in the cluster total...
SELECT total_size_in_bytes < 10 * 1048576 AS blind_load_invisible
FROM diskquota.show_cluster_quota_view;
-- ...and monitored databases stay writable
INSERT INTO cdqschema.cdq_t2 VALUES (1, 'x');
-- monitor the blind database; initialize its existing data
\c cdq_blind
CREATE EXTENSION diskquota;
SELECT diskquota.init_table_size_table();
SELECT diskquota.wait_for_worker_new_epoch();
\c contrib_regression
SELECT diskquota.wait_for_worker_new_epoch();
-- the same ~15 MB is now visible and over the cap
SELECT total_size_in_bytes > 10 * 1048576 AS blind_load_visible
FROM diskquota.show_cluster_quota_view;
-- expect fail: the cap now bites in every monitored database
INSERT INTO cdqschema.cdq_t2 VALUES (2, 'x');
-- stop monitoring the blind database; its size leaves the total
\c cdq_blind
SELECT diskquota.pause();
SELECT diskquota.wait_for_worker_new_epoch();
DROP EXTENSION diskquota;
\c contrib_regression
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.wait_for_worker_new_epoch();
SELECT total_size_in_bytes < 10 * 1048576 AS unmonitored_excluded
FROM diskquota.show_cluster_quota_view;
INSERT INTO cdqschema.cdq_t2 VALUES (3, 'x');
DROP DATABASE cdq_blind;

-- === reaper: a dropped database's usage must leave the total ===
-- monitor a database, fill it past the cap, then DROP DATABASE
-- without DROP EXTENSION first: the launcher must release the dead
-- database's bookkeeping so it stops counting toward the cluster cap
CREATE DATABASE cdq_phantom;
\c cdq_phantom
CREATE EXTENSION diskquota;
CREATE TABLE phantom_t (i INT, t TEXT) DISTRIBUTED BY (i);
INSERT INTO phantom_t SELECT g, repeat('x', 1000) FROM generate_series(1, 15000) g;
SELECT diskquota.wait_for_worker_new_epoch();
\c contrib_regression
SET search_path TO cdqschema;
-- the phantom load counts while its database exists
SELECT total_size_in_bytes > 10 * 1048576 AS phantom_counted
FROM diskquota.show_cluster_quota_view;
-- expect fail: over the cap
INSERT INTO cdqschema.cdq_t2 VALUES (4, 'x');
-- drop the database directly; retry while its worker's transient
-- connections block the drop (prints DROPPED once it goes through)
\! for i in $(seq 1 30); do psql -d contrib_regression -Atc "DROP DATABASE cdq_phantom" >/dev/null 2>&1 && { echo DROPPED; break; }; sleep 1; done
-- bounded wait for the launcher to reap the dead slot
DO $$ BEGIN FOR i IN 1..600 LOOP EXIT WHEN diskquota.cluster_total_size() < 10 * 1048576; PERFORM pg_sleep(0.1); END LOOP; END $$;
SELECT total_size_in_bytes < 10 * 1048576 AS phantom_reaped
FROM diskquota.show_cluster_quota_view;
-- one worker cycle to clear the stale rejectmap entry; writes resume
SELECT diskquota.wait_for_worker_new_epoch();
INSERT INTO cdqschema.cdq_t2 VALUES (5, 'x');

-- === setter input validation ===
-- expect fail: the limit would overflow the internal byte computation
SELECT diskquota.set_database_quota(current_database()::text, '10000000000000 MB');
-- expect fail: same cap on the cluster quota
SELECT diskquota.set_cluster_quota('10000000000000 MB');
-- expect fail: set_cluster_quota persists outside the caller's
-- transaction, so it refuses to run inside an explicit block
BEGIN;
SELECT diskquota.set_cluster_quota('100 MB');
ROLLBACK;
-- a rolled-back database-quota set must never reach enforcement: the
-- worker is the only publisher of limits to shared memory
BEGIN;
SELECT diskquota.set_database_quota(current_database()::text, '1 MB');
ROLLBACK;
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.database_quota_limit_mb();

SELECT diskquota.set_cluster_quota('-1');
SELECT diskquota.wait_for_worker_new_epoch();
DROP TABLE cdqschema.cdq_t2;
RESET search_path;
DROP SCHEMA cdqschema;
