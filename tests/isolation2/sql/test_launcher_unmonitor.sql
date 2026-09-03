-- A DROP EXTENSION whose segment-side unmonitor dispatch fails queues a
-- retry that carries only the database oid. A DROP EXTENSION leaves the
-- oid unchanged, so a CREATE EXTENSION that re-monitors the same database
-- before the retry runs must not have its monitoring torn down by the
-- stale retry. The retry is held with a fault so the DROP and the
-- re-CREATE are both in place before it runs; db_status() reads the
-- coordinator's monitored-database cache, which update_monitor_db_mpp
-- maintains alongside the segments'.
1: CREATE DATABASE unmon_db;
1q:
2:@db_name unmon_db: CREATE EXTENSION diskquota;
2:@db_name unmon_db: CREATE EXTENSION diskquota_test;
2:@db_name unmon_db: SELECT diskquota.wait_for_worker_new_epoch();

-- monitored: unmon_db is in the monitored-database cache
2:@db_name unmon_db: SELECT count(*) AS monitored_before FROM diskquota_test.db_status() WHERE datname = 'unmon_db';

-- Hold the unmonitor retry, then fail the DROP's segment-side dispatch:
-- the launcher queues a retry for unmon_db's oid but leaves the cache
-- entry in place (the remove never dispatched).
SELECT gp_inject_fault_infinite('diskquota_pending_unmonitor_retry', 'skip', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
SELECT gp_inject_fault_infinite('diskquota_drop_unmonitor', 'error', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
2:@db_name unmon_db: DROP EXTENSION diskquota;
SELECT gp_inject_fault('diskquota_drop_unmonitor', 'reset', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;

-- Re-monitor the same database (same oid) while the retry is still held.
2:@db_name unmon_db: CREATE EXTENSION diskquota;
2:@db_name unmon_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name unmon_db: SELECT diskquota.wait_for_worker_new_epoch();

-- Release the retry and let it run: it must see unmon_db's live slot and
-- drop the stale unmonitor instead of removing the re-created database.
SELECT gp_inject_fault('diskquota_pending_unmonitor_retry', 'reset', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
2:@db_name unmon_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name unmon_db: SELECT diskquota.wait_for_worker_new_epoch();

2:@db_name unmon_db: SELECT count(*) AS monitored_after_retry FROM diskquota_test.db_status() WHERE datname = 'unmon_db';

-- cleanup
2:@db_name unmon_db: DROP EXTENSION diskquota_test;
2:@db_name unmon_db: DROP EXTENSION diskquota;
2q:
1: DROP DATABASE unmon_db;
1q:
