-- CREATE EXTENSION must not enable segment-side monitoring for a database
-- that could not obtain a launcher dbArray slot. The phase-1 num_db guard
-- can pass while a draining slot still fills the array, so the shortage
-- surfaces only in the post-commit add_db_entry(). A fault simulates that
-- full array. The CREATE must fail, undo its phase-1 database_list row, and
-- leave no worker -- not report success with the segments enforcing a
-- database the coordinator has no slot, worker, or accounting for.
1: CREATE DATABASE no_slot_db;

-- simulate a full dbArray for the next add_db_entry (fires in the launcher)
1: SELECT gp_inject_fault_infinite('diskquota_add_db_entry_full', 'skip', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;

-- the CREATE reaches the launcher, whose add_db_entry() finds no slot
2:@db_name no_slot_db: CREATE EXTENSION diskquota;

-- stop simulating the full array
1: SELECT gp_inject_fault('diskquota_add_db_entry_full', 'reset', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;

-- the phase-1 database_list row was undone: the launcher's 'diskquota'
-- database holds no row for no_slot_db
3:@db_name diskquota: SELECT count(*) AS leaked_rows FROM diskquota_namespace.database_list WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'no_slot_db');

-- and no worker was started for it
1: SELECT count(*) AS workers FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'no_slot_db';

-- the failed CREATE rolled back: the extension is not present
2:@db_name no_slot_db: SELECT count(*) AS ext FROM pg_extension WHERE extname = 'diskquota';

-- the message box is not wedged: a normal CREATE now succeeds and is served
2:@db_name no_slot_db: CREATE EXTENSION diskquota;
2:@db_name no_slot_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name no_slot_db: SELECT count(*) AS workers_now FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'no_slot_db';

-- cleanup
2:@db_name no_slot_db: DROP EXTENSION diskquota;
2q:
3q:
1: DROP DATABASE no_slot_db;
1q:
