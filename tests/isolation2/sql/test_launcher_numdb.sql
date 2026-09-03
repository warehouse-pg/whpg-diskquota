-- num_db is the launcher's running count of live dbArray slots, and it
-- decides worker scheduling: once it exceeds diskquota.max_workers the
-- launcher switches to dynamic workers so databases past the limit still
-- get served in rotation. The count must follow the real slot changes,
-- not the CREATE/DROP messages: a duplicate DROP -- a timed-out drop
-- whose cleanup re-drops an already-unmonitored database -- deletes zero
-- rows from database_list yet still succeeds, and counting that would
-- push num_db below the live slot count and silently drop the launcher
-- out of dynamic mode, starving a database that is still monitored.
--
-- max_workers is lowered to 1 so three monitored databases already force
-- dynamic mode and the count is observable through
-- diskquota_test.is_dynamic_worker() (num_db itself is launcher-process
-- local and not visible from a backend). The single wait below rides out
-- the sender's full drop timeout with the launcher parked, so this is a
-- slow protocol test by nature.
!\retcode gpconfig -c diskquota.max_workers -v 1 --skipvalidation > /dev/null;
!\retcode gpstop -raf > /dev/null;

1: CREATE DATABASE numdb_a;
1: CREATE DATABASE numdb_b;
1: CREATE DATABASE numdb_c;
1q:

2:@db_name numdb_a: CREATE EXTENSION diskquota;
2:@db_name numdb_a: CREATE EXTENSION diskquota_test;
3:@db_name numdb_b: CREATE EXTENSION diskquota;
4:@db_name numdb_c: CREATE EXTENSION diskquota;

-- three live slots, one worker allowed: dynamic mode is on
2:@db_name numdb_a: SELECT diskquota_test.is_dynamic_worker() AS three_dbs_dynamic;

-- Suspend the launcher mid-DROP of numdb_c. The fault sits just after
-- release_db_entry(), so the slot is already freed (num_db -> 2) when the
-- DROP session times out and rolls back: numdb_c stays installed in the
-- catalog with its launcher slot gone -- exactly the state a retry then
-- re-drops.
SELECT gp_inject_fault_infinite('diskquota_drop_unmonitor', 'suspend', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
4&:@db_name numdb_c: DROP EXTENSION diskquota;
SELECT gp_wait_until_triggered_fault('diskquota_drop_unmonitor', 1, dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;
4<:
SELECT gp_inject_fault_infinite('diskquota_drop_unmonitor', 'reset', dbid)
  FROM gp_segment_configuration WHERE role='p' AND content=-1;

-- two live slots (numdb_a, numdb_b) remain, still above the limit
2:@db_name numdb_a: SELECT diskquota_test.is_dynamic_worker() AS two_dbs_dynamic;

-- The duplicate DROP: numdb_c's database_list row is already gone, so
-- this deletes zero rows and frees no slot. num_db must stay 2 and the
-- launcher must stay in dynamic mode; the buggy accounting decremented
-- again to 1 (= max_workers) and cleared dynamic mode.
4:@db_name numdb_c: DROP EXTENSION diskquota;
2:@db_name numdb_a: SELECT diskquota_test.is_dynamic_worker() AS still_dynamic_after_dup_drop;

-- cleanup
2:@db_name numdb_a: DROP EXTENSION diskquota_test;
2:@db_name numdb_a: DROP EXTENSION diskquota;
3:@db_name numdb_b: DROP EXTENSION diskquota;
2q:
3q:
4q:
1: DROP DATABASE numdb_a;
1: DROP DATABASE numdb_b;
1: DROP DATABASE numdb_c;
1q:

!\retcode gpconfig -c diskquota.max_workers -v 10 --skipvalidation > /dev/null;
!\retcode gpstop -raf > /dev/null;
