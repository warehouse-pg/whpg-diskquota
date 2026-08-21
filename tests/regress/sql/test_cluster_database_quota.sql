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
RESET search_path;
DROP SCHEMA cdqschema;
