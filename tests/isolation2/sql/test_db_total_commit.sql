-- The worker publishes a database's total size to launcher shmem, where
-- the cluster-wide quota reads it. That total must never reflect a
-- refresh transaction that later aborted: the flush to diskquota.table_size
-- rolls back with the transaction, and a shmem total left ahead of it
-- makes the cluster count usage that was rolled back. Here a fault fails
-- the rejectmap dispatch so every refresh aborts after the flush; the
-- shmem total must stay equal to the committed table_size.
--
-- hardlimit is on so an active table forces the dispatch (and thus the
-- fault) each cycle.
!\retcode gpconfig -c "diskquota.hard_limit" -v "on" > /dev/null;
!\retcode gpstop -u > /dev/null;

1: CREATE DATABASE dbtotal_db;
1q:
2:@db_name dbtotal_db: CREATE EXTENSION diskquota;
2:@db_name dbtotal_db: CREATE TABLE dbt (i int) DISTRIBUTED BY (i);
2:@db_name dbtotal_db: INSERT INTO dbt SELECT generate_series(1, 100000);
2:@db_name dbtotal_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name dbtotal_db: SELECT diskquota.wait_for_worker_new_epoch();

-- committed baseline: the published per-database total equals the flushed
-- table_size
2:@db_name dbtotal_db: SELECT diskquota.database_total_size() = (SELECT COALESCE(sum(size), 0) FROM diskquota.table_size WHERE segid = -1) AS shmem_matches_committed;

-- Fail the rejectmap dispatch so every refresh aborts after the point
-- where the buggy code published the total.
SELECT gp_inject_fault_infinite('diskquota_dispatch_rejectmap', 'error', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;

-- Grow the table: the rows commit on disk, but the worker's flush of the
-- larger size is rolled back with the aborted refresh, so table_size stays
-- at the committed baseline.
2:@db_name dbtotal_db: INSERT INTO dbt SELECT generate_series(1, 400000);
2:@db_name dbtotal_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name dbtotal_db: SELECT diskquota.wait_for_worker_new_epoch();

-- The shmem total must still equal the committed table_size: the aborted
-- refresh must not have advanced it.
2:@db_name dbtotal_db: SELECT diskquota.database_total_size() = (SELECT COALESCE(sum(size), 0) FROM diskquota.table_size WHERE segid = -1) AS shmem_matches_committed;

SELECT gp_inject_fault('diskquota_dispatch_rejectmap', 'reset', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;

-- cleanup
2:@db_name dbtotal_db: DROP EXTENSION diskquota;
2q:
1: DROP DATABASE dbtotal_db;
1q:
!\retcode gpconfig -c "diskquota.hard_limit" -v "off" > /dev/null;
!\retcode gpstop -u > /dev/null;
