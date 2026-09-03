-- When a CREATE EXTENSION fails after add_db_entry() has already claimed a
-- dbArray slot (e.g. the segment registration dispatch errors), the launcher
-- must tear the half-created monitoring down: the shmem slot mutation is not
-- transactional, so without compensation the database would stay monitored
-- (slot claimed, phase-1 database_list row committed, worker started next
-- iteration) even though CREATE EXTENSION reported failure. The fault fires
-- after the slot is claimed but before the segments are told to monitor.
1: CREATE DATABASE cps_db;

-- fail the CREATE's post-commit phase after the slot is claimed
1: SELECT gp_inject_fault_infinite('diskquota_create_post_slot', 'error', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;

-- the CREATE claims a slot, then the dispatch step fails
2:@db_name cps_db: CREATE EXTENSION diskquota;

-- stop failing
1: SELECT gp_inject_fault('diskquota_create_post_slot', 'reset', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;

-- compensation ran: the committed phase-1 database_list row is gone
3:@db_name diskquota: SELECT count(*) AS leaked_rows FROM diskquota_namespace.database_list WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'cps_db');

-- no worker is left running for the failed database
1: SELECT count(*) AS workers FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'cps_db';

-- the failed CREATE rolled back: the extension is not present
2:@db_name cps_db: SELECT count(*) AS ext FROM pg_extension WHERE extname = 'diskquota';

-- the claimed slot was released: a normal CREATE now succeeds and is served
2:@db_name cps_db: CREATE EXTENSION diskquota;
2:@db_name cps_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name cps_db: SELECT count(*) AS workers_now FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'cps_db';

-- cleanup
2:@db_name cps_db: DROP EXTENSION diskquota;
2q:
3q:
1: DROP DATABASE cps_db;
1q:
