-- Cluster and database quotas must survive a postmaster restart:
-- the launcher reloads the cluster limit from its global config
-- table, the database worker re-reads its settings row, and the
-- scoreboard totals are republished from diskquota.table_size.

-- run under soft limit only: pin hard_limit off in every process
!\retcode gpconfig -c "diskquota.hard_limit" -v "off" > /dev/null;
!\retcode gpstop -u > /dev/null;

1: CREATE SCHEMA cqr_s;
1: CREATE TABLE cqr_s.t (i INT, t TEXT) DISTRIBUTED BY (i);
1: SELECT diskquota.set_cluster_quota('10 MB');
1: SELECT diskquota.set_database_quota(current_database()::text, '8 MB');
1: SELECT diskquota.wait_for_worker_new_epoch();
-- starts under the caps, so the load completes (soft limit)
1: INSERT INTO cqr_s.t SELECT g, repeat('x', 1000) FROM generate_series(1, 15000) g;
1: SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail: both caps exceeded (the database cap is checked first)
1: INSERT INTO cqr_s.t VALUES (1, 'x');
1q:

-- hard restart of the coordinator postmaster
!\retcode pg_ctl -D $MASTER_DATA_DIRECTORY -w stop;
!\retcode @POSTMASTER_START_CMD@;
!\retcode sleep 5;

-- both limits must have survived the restart without being re-set
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.cluster_quota_limit_mb();
1: SELECT diskquota.database_quota_limit_mb();
-- expect fail: scoreboard republished, enforcement still bites
1: INSERT INTO cqr_s.t VALUES (2, 'x');
-- delete the quotas; writes resume
1: SELECT diskquota.set_cluster_quota('-1');
1: SELECT diskquota.set_database_quota(current_database()::text, '-1');
1: SELECT diskquota.wait_for_worker_new_epoch();
1: INSERT INTO cqr_s.t VALUES (3, 'x');
1: DROP SCHEMA cqr_s CASCADE;
1q:
