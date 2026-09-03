-- A failed CREATE EXTENSION queues a durable teardown (delete the committed
-- phase-1 database_list row and stop segment monitoring), retried until it
-- commits. That retry commit is a distributed commit and can itself fail (a
-- segment down at 2PC). It must be caught in the launcher, not escape and
-- terminate the handler-less launcher main loop -- if the launcher died and
-- was restarted, its startup replay would resurrect monitoring for the very
-- database whose CREATE reported failure, and the process-local retry queue
-- would be lost. Force the retry's own commit to fail, prove the launcher
-- survives and keeps the teardown queued, then release the fault and confirm
-- the row is durably removed.
1: CREATE DATABASE rcf_db;

-- hold the teardown retry so the committed phase-1 row survives until we have
-- armed the commit failure below
1: SELECT gp_inject_fault_infinite('diskquota_pending_unmonitor_retry', 'skip', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
-- fail the CREATE after the slot is claimed: this queues the pending teardown
1: SELECT gp_inject_fault_infinite('diskquota_create_post_slot', 'error', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
2:@db_name rcf_db: CREATE EXTENSION diskquota;
1: SELECT gp_inject_fault('diskquota_create_post_slot', 'reset', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;

-- arm the commit failure, then release the retry hold: the teardown retry now
-- runs, but its distributed commit fails on every pass
1: SELECT gp_inject_fault_infinite('diskquota_launcher_commit_fail', 'error', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
1: SELECT gp_inject_fault('diskquota_pending_unmonitor_retry', 'reset', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
-- give the launcher several main-loop passes to attempt (and fail) the retry
1: SELECT pg_sleep(2);

-- the launcher survived the failed commits: it did NOT restart and resurrect
-- monitoring (no worker for rcf_db), and the queued teardown is retained --
-- the committed phase-1 row is still present, not lost and not re-monitored
1: SELECT count(*) AS workers FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'rcf_db';
3:@db_name diskquota: SELECT count(*) AS row_retained FROM diskquota_namespace.database_list l JOIN pg_database d ON d.oid = l.dbid WHERE d.datname = 'rcf_db';

-- release the fault; the retry now commits and drops the row
1: SELECT gp_inject_fault('diskquota_launcher_commit_fail', 'reset', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
!\retcode for i in $(seq 1 60); do n=$(psql -d diskquota -Atc "SELECT count(*) FROM diskquota_namespace.database_list l JOIN pg_database d ON d.oid = l.dbid WHERE d.datname = 'rcf_db'" 2>/dev/null); [ "$n" = "0" ] && break; sleep 1; done;

-- the teardown completed: row durably gone, still no worker
3:@db_name diskquota: SELECT count(*) AS row_cleaned FROM diskquota_namespace.database_list l JOIN pg_database d ON d.oid = l.dbid WHERE d.datname = 'rcf_db';
1: SELECT count(*) AS workers FROM pg_stat_activity WHERE backend_type LIKE 'diskquota bgworker%' AND datname = 'rcf_db';

-- cleanup
2q:
3q:
1: DROP DATABASE rcf_db;
1q:
