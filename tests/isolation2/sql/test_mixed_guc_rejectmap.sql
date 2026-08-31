-- Guard the mixed-GUC rejectmap wedge: an entry dispatched to the
-- segments while hard_limit was on must be withdrawn when its quota
-- is deleted, even if the coordinator has meanwhile turned
-- hard_limit off and the segments have not seen the change yet
-- (partial reload). The worker dispatches entry REMOVALS regardless
-- of its own copy of the GUC; without that, the segments would keep
-- rejecting on the deleted quota until their next reload.

-- hard_limit on everywhere
!\retcode gpconfig -c "diskquota.hard_limit" -v "on" > /dev/null;
!\retcode gpstop -u > /dev/null;

1: CREATE SCHEMA mixed_s;
1: SELECT diskquota.set_schema_quota('mixed_s', '1 MB');
1: SELECT diskquota.wait_for_worker_new_epoch();
-- exceed the quota; the worker dispatches a rejectmap entry
1: CREATE TABLE mixed_s.t1 AS SELECT generate_series(1, 100000) DISTRIBUTED BY (generate_series);
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.wait_for_worker_new_epoch();
-- the entry reached the segments
1: SELECT count(*) > 0 AS entry_on_segments FROM gp_dist_random('diskquota.rejectmap');
-- expect fail: hardlimit rejects new relations of the schema
1: CREATE TABLE mixed_s.t2 AS SELECT generate_series(1, 100) DISTRIBUTED BY (generate_series);

-- turn hard_limit off on the COORDINATOR ONLY: gpconfig writes every
-- config file, but only the coordinator postmaster is reloaded. The
-- segments keep their in-memory hard_limit=on and keep enforcing
-- whatever rejectmap they last received.
!\retcode gpconfig -c "diskquota.hard_limit" -v "off" > /dev/null;
!\retcode pg_ctl -D $MASTER_DATA_DIRECTORY reload > /dev/null;

-- delete the quota; the removal must still reach the segments
1: SELECT diskquota.set_schema_quota('mixed_s', '-1');
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT count(*) AS entries_left_on_segments FROM gp_dist_random('diskquota.rejectmap');
-- writes to the previously blocked relation resume: its stale
-- relfilenode entries would otherwise still be enforced by the
-- segments, which run with hard_limit=on
1: INSERT INTO mixed_s.t1 SELECT generate_series(1, 100000);
1: DROP SCHEMA mixed_s CASCADE;
1q:

-- === object-independent quotas must never plant keyed entries in ===
-- === segment rejectmaps: those are indexed by relfilenode        ===
!\retcode gpconfig -c "diskquota.hard_limit" -v "on" > /dev/null;
!\retcode gpstop -u > /dev/null;

1: CREATE SCHEMA mixed_s2;
1: CREATE TABLE mixed_s2.t (i INT) DISTRIBUTED BY (i);
1: INSERT INTO mixed_s2.t SELECT generate_series(1, 100000);
-- silence the unmonitored-databases warning: environment-dependent
1: SET client_min_messages = error;
1: SELECT diskquota.set_cluster_quota('1 MB');
1: RESET client_min_messages;
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.wait_for_worker_new_epoch();
-- the keyed entry exists on the coordinator...
1: SELECT count(*) > 0 AS qd_has_cluster_entry FROM diskquota.rejectmap WHERE target_type = 'CLUSTER_QUOTA';
-- ...but never reaches the segments in keyed (relnode = 0) form
1: SELECT count(*) AS keyed_entries_on_segments FROM gp_dist_random('diskquota.rejectmap') WHERE relnode = 0;
1: SELECT diskquota.set_cluster_quota('-1');
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.wait_for_worker_new_epoch();
1: DROP SCHEMA mixed_s2 CASCADE;
1q:

-- === a dispatch the segments never received must be retried:     ===
-- === otherwise a removal is lost while the segments keep         ===
-- === enforcing the deleted quota forever                         ===
1: CREATE SCHEMA mixed_s3;
1: SELECT diskquota.set_schema_quota('mixed_s3', '1 MB');
1: CREATE TABLE mixed_s3.t1 AS SELECT generate_series(1, 100000) DISTRIBUTED BY (generate_series);
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT count(*) > 0 AS entry_on_segments FROM gp_dist_random('diskquota.rejectmap');
-- kill every rejectmap dispatch, then delete the quota: the removal
-- cannot reach the segments while the fault is active
1: SELECT gp_inject_fault_infinite('diskquota_dispatch_rejectmap', 'error', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
1: SELECT diskquota.set_schema_quota('mixed_s3', '-1');
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT count(*) > 0 AS stale_entries_while_fault FROM gp_dist_random('diskquota.rejectmap');
-- lift the fault: the worker still remembers the unconfirmed
-- dispatch and resends, clearing the stale entries
1: SELECT gp_inject_fault_infinite('diskquota_dispatch_rejectmap', 'reset', dbid) FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT count(*) AS entries_after_retry FROM gp_dist_random('diskquota.rejectmap');
-- writes to the previously blocked relation resume
1: INSERT INTO mixed_s3.t1 SELECT generate_series(1, 100);
1: DROP SCHEMA mixed_s3 CASCADE;
1q:

-- === a dropped database's rejectmap entries must leave the segments ===
-- DROP DATABASE without DROP EXTENSION: the launcher's reaper tears
-- the database down, and its dispatched REMOVE must also purge the
-- segment rejectmaps -- with no worker left to dispatch a
-- replacement, stale entries would occupy the fixed-size maps forever
1: CREATE DATABASE mixed_reaper;
2:@db_name mixed_reaper: CREATE EXTENSION diskquota;
2:@db_name mixed_reaper: CREATE SCHEMA rs;
2:@db_name mixed_reaper: CREATE TABLE rs.t (i INT) DISTRIBUTED BY (i);
2:@db_name mixed_reaper: INSERT INTO rs.t SELECT generate_series(1, 100000);
-- let the fresh database's bookkeeping settle before arming the
-- quota: a dispatch re-derives the segment entries from the tables
-- active in that cycle, so churn right after the overage would wipe
-- what this test wants to observe
2:@db_name mixed_reaper: SELECT diskquota.init_table_size_table();
2:@db_name mixed_reaper: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mixed_reaper: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mixed_reaper: SELECT diskquota.set_schema_quota('rs', '1 MB');
2:@db_name mixed_reaper: INSERT INTO rs.t SELECT generate_series(1, 10000);
2:@db_name mixed_reaper: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mixed_reaper: SELECT diskquota.wait_for_worker_new_epoch();
1: SELECT count(*) > 0 AS phantom_entries_on_segments FROM gp_dist_random('diskquota.rejectmap');
2q:
!\retcode for i in $(seq 1 30); do psql -d isolation2test -Atc "DROP DATABASE mixed_reaper" >/dev/null 2>&1 && break; sleep 1; done;
-- give the reaper a launcher pass and the purge a dispatch
!\retcode sleep 10;
1: SELECT count(*) AS entries_left_on_segments FROM gp_dist_random('diskquota.rejectmap');
1q:

-- reload the segments too: hard_limit off everywhere again
!\retcode gpconfig -c "diskquota.hard_limit" -v "off" > /dev/null;
!\retcode gpstop -u > /dev/null;
