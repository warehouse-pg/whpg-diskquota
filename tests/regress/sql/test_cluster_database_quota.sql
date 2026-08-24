-- Test cluster-wide and per-database disk quota (PTT-1563)
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
SELECT diskquota.set_cluster_quota('1 GB');
SELECT diskquota.cluster_quota_limit_mb();
SELECT diskquota.wait_for_worker_new_epoch();
-- writes resume under the raised cap
INSERT INTO cdqschema.cdq_t VALUES (1, 'x');
-- lower it back under current usage; the cap bites again
SELECT diskquota.set_cluster_quota('10 MB');
SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail: over the lowered cap again
INSERT INTO cdqschema.cdq_t VALUES (1, 'x');
-- a new database can start being monitored while the cluster is over
-- the cap: CREATE EXTENSION goes through the launcher's bookkeeping
CREATE DATABASE cdq_join;
\c cdq_join
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
SELECT diskquota.set_cluster_quota('-1');
SELECT diskquota.wait_for_worker_new_epoch();
DROP TABLE cdqschema.cdq_t2;
RESET search_path;
DROP SCHEMA cdqschema;
