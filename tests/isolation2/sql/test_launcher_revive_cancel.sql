-- A DROP after a re-CREATE, while the old worker is still draining, must
-- cancel the pending revive: DROP -> CREATE -> DROP must free the slot once
-- the old worker leaves, not resurrect the dropped database. The old worker
-- is parked in its refresh loop with a fault so it cannot exit, the whole
-- DROP/CREATE/DROP runs against the held slot, and after the worker is
-- released the database must have no worker (the slot was freed, not
-- reactivated).
1: CREATE DATABASE revive_db;
1q:
2:@db_name revive_db: CREATE EXTENSION diskquota;
2:@db_name revive_db: SELECT diskquota.wait_for_worker_new_epoch();

-- park the worker in its refresh loop so it cannot exit on a drop's SIGTERM
SELECT gp_inject_fault_infinite('diskquota_worker_main', 'suspend', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
SELECT gp_wait_until_triggered_fault('diskquota_worker_main', 1, dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;

-- exactly one worker: the parked old one
2:@db_name revive_db: SELECT count(*) AS one_worker FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'revive_db';

-- DROP -> CREATE -> DROP, all while the old worker cannot exit. The CREATE
-- re-monitors the still-draining slot (revive pending); the second DROP must
-- cancel that revive.
2:@db_name revive_db: DROP EXTENSION diskquota;
2:@db_name revive_db: CREATE EXTENSION diskquota;
2:@db_name revive_db: DROP EXTENSION diskquota;

-- wait past the point a new worker would have started: still only the parked
-- old worker, no new incarnation on the held slot
2:@db_name revive_db: SELECT pg_sleep(5);
2:@db_name revive_db: SELECT count(*) AS still_one_worker FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'revive_db';

-- release the old worker: it exits and the launcher reaps the slot. Because
-- the last DROP cancelled the revive, the slot is freed, so no new worker
-- starts for revive_db.
SELECT gp_inject_fault('diskquota_worker_main', 'reset', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
2:@db_name revive_db: SELECT pg_sleep(5);
2:@db_name revive_db: SELECT count(*) AS no_worker FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'revive_db';

-- cleanup
2q:
1: DROP DATABASE revive_db;
1q:
