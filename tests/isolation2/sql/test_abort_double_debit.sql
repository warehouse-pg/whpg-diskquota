-- A table dropped while a schema quota is set must have its size subtracted
-- from the schema's in-memory quota total exactly once. The subtraction
-- happens in calculate_table_disk_usage(); the table_size entry that carries
-- the size is removed only by the post-commit flush. If a refresh aborts
-- after the subtraction but before that flush, the entry survives and the
-- next refresh subtracts the same bytes again. Repeated over several aborted
-- cycles this drives the schema's model total far below true usage, so the
-- schema is no longer rejected even when it truly exceeds its quota.
--
-- A fault fails the rejectmap dispatch so every refresh aborts after the
-- subtraction; hardlimit is enabled for the drift phase (with a no-quota
-- table kept active) so a dispatch, and thus the fault, fires each cycle.
-- After the drift the schema is refilled past its quota and must still be
-- enforced. Pre-fix the drifted-negative total leaves it unrejected and the
-- write wrongly succeeds. Enforcement is checked with soft-limit (hardlimit
-- off), whose rejection is coordinator-side and deterministic.
!\retcode gpconfig -c "diskquota.hard_limit" -v "off" > /dev/null;
!\retcode gpstop -u > /dev/null;

1: CREATE DATABASE abort_dd_db;
1q:
2:@db_name abort_dd_db: CREATE EXTENSION diskquota;
2:@db_name abort_dd_db: CREATE SCHEMA s;
2:@db_name abort_dd_db: CREATE SCHEMA act;
2:@db_name abort_dd_db: CREATE TABLE act.driver (i int) DISTRIBUTED BY (i);
-- fill s.counted (~50 MB) before any quota/hardlimit applies, so the fill is
-- never rejected mid-statement (that would race the worker's dispatch)
2:@db_name abort_dd_db: CREATE TABLE s.counted (t text) DISTRIBUTED BY (t);
2:@db_name abort_dd_db: INSERT INTO s.counted SELECT repeat('x', 900) FROM generate_series(1, 60000);
2:@db_name abort_dd_db: CREATE TABLE s.probe (i int) DISTRIBUTED BY (i);
2:@db_name abort_dd_db: SELECT diskquota.set_schema_quota('s', '1 MB');
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();

-- baseline: schema s is over its 1 MB quota, so a write to it is rejected
2:@db_name abort_dd_db: INSERT INTO s.probe VALUES (1);

-- enable hardlimit so an active table forces a dispatch (and the abort fault)
-- every refresh cycle during the drift phase
!\retcode gpconfig -c "diskquota.hard_limit" -v "on" > /dev/null;
!\retcode gpstop -u > /dev/null;

-- arm: every refresh now aborts after calculate_table_disk_usage() has
-- subtracted the counted table's size
SELECT gp_inject_fault_infinite('diskquota_dispatch_rejectmap', 'error', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;

-- drop the counted table; its ~50 MB is subtracted from schema s on every
-- aborted cycle. Each act.driver write keeps a table active so the dispatch
-- (and the fault) fires, and always succeeds (act has no quota).
2:@db_name abort_dd_db: DROP TABLE s.counted;
2:@db_name abort_dd_db: INSERT INTO act.driver VALUES (1);
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name abort_dd_db: INSERT INTO act.driver VALUES (2);
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name abort_dd_db: INSERT INTO act.driver VALUES (3);
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name abort_dd_db: INSERT INTO act.driver VALUES (4);
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();

-- lift the fault and return to soft-limit only for a deterministic
-- enforcement check
SELECT gp_inject_fault('diskquota_dispatch_rejectmap', 'reset', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
!\retcode gpconfig -c "diskquota.hard_limit" -v "off" > /dev/null;
!\retcode gpstop -u > /dev/null;
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();

-- refill schema s well past its 1 MB quota (soft-limit lets the statement in
-- because the schema is under quota when it starts)
2:@db_name abort_dd_db: INSERT INTO s.probe SELECT generate_series(1, 500000);
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name abort_dd_db: SELECT diskquota.wait_for_worker_new_epoch();

-- schema s is truly over quota: the write must be rejected. Pre-fix the
-- drifted-negative model total leaves it unrejected and this INSERT succeeds.
2:@db_name abort_dd_db: INSERT INTO s.probe VALUES (2);

-- cleanup
2:@db_name abort_dd_db: DROP EXTENSION diskquota;
2q:
1: DROP DATABASE abort_dd_db;
1q:
