-- The launcher must not recycle a database's slot for a new incarnation
-- while the old worker is still running. After SIGTERM a worker finishes
-- its current refresh cycle, and until it stops it can flush table_size,
-- rewrite the shared rejectmap, and advance the database's epoch; a new
-- incarnation started meanwhile would race it on that shared state. Here
-- the old worker is parked in its refresh loop with a fault, then the
-- database is dropped and re-created: no new worker may start until the
-- old one leaves.
1: CREATE DATABASE lifetime_db;
1q:
2:@db_name lifetime_db: CREATE EXTENSION diskquota;
2:@db_name lifetime_db: SELECT diskquota.wait_for_worker_new_epoch();

-- park the worker in its refresh loop so it cannot exit on the drop's
-- SIGTERM
SELECT gp_inject_fault_infinite('diskquota_worker_main', 'suspend', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
SELECT gp_wait_until_triggered_fault('diskquota_worker_main', 1, dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;

-- exactly one worker: the parked old one
2:@db_name lifetime_db: SELECT count(*) AS one_worker FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'lifetime_db';

-- drop and re-create while the old worker cannot exit
2:@db_name lifetime_db: DROP EXTENSION diskquota;
2:@db_name lifetime_db: CREATE EXTENSION diskquota;

-- wait well past the point a new worker would have started, then confirm
-- the new incarnation is still deferred: only the parked old worker exists
2:@db_name lifetime_db: SELECT pg_sleep(5);
2:@db_name lifetime_db: SELECT count(*) AS still_one_worker FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'lifetime_db';

-- release the old worker: it exits and the new incarnation takes over
SELECT gp_inject_fault('diskquota_worker_main', 'reset', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
2:@db_name lifetime_db: SELECT diskquota.wait_for_worker_new_epoch();

-- cleanup
2:@db_name lifetime_db: DROP EXTENSION diskquota;
2q:
1: DROP DATABASE lifetime_db;
1q:
