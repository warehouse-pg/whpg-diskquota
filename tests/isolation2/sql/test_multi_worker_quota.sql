-- Multiple dedicated workers running concurrently: isolation2 runs
-- with the default diskquota.max_workers (10), so every database
-- below gets its own worker. The rest of the suites run with one
-- worker, so this is the coverage for the multi-worker invariants:
-- each worker publishes its own database's limit and total into its
-- own launcher slot, every worker's total feeds the cluster view,
-- enforcement stays per-database, and one database's rejectmap
-- dispatch never disturbs another database's segment entries.
!\retcode gpconfig -c "diskquota.hard_limit" -v "on" > /dev/null;
!\retcode gpstop -u > /dev/null;

1: CREATE DATABASE mw1;
1: CREATE DATABASE mw2;
1: CREATE DATABASE mw3;
1q:

2:@db_name mw1: CREATE EXTENSION diskquota;
3:@db_name mw2: CREATE EXTENSION diskquota;
4:@db_name mw3: CREATE EXTENSION diskquota;

-- === concurrent publishes: each worker fills its own slot ===
2:@db_name mw1: SELECT diskquota.set_database_quota('mw1', '111 MB');
3:@db_name mw2: SELECT diskquota.set_database_quota('mw2', '222 MB');
2:@db_name mw1: CREATE TABLE t1 AS SELECT generate_series(1, 100000) DISTRIBUTED BY (generate_series);
3:@db_name mw2: CREATE TABLE t2 AS SELECT generate_series(1, 100000) DISTRIBUTED BY (generate_series);
4:@db_name mw3: CREATE TABLE t3 AS SELECT generate_series(1, 100000) DISTRIBUTED BY (generate_series);
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
3:@db_name mw2: SELECT diskquota.wait_for_worker_new_epoch();
3:@db_name mw2: SELECT diskquota.wait_for_worker_new_epoch();
4:@db_name mw3: SELECT diskquota.wait_for_worker_new_epoch();
4:@db_name mw3: SELECT diskquota.wait_for_worker_new_epoch();

-- each limit landed in its own slot: no cross-database bleed
2:@db_name mw1: SELECT quota_in_mb FROM diskquota.show_database_quota_view;
3:@db_name mw2: SELECT quota_in_mb FROM diskquota.show_database_quota_view;
4:@db_name mw3: SELECT quota_in_mb FROM diskquota.show_database_quota_view;
-- every worker's published total feeds the cluster sum: each of the
-- three loads alone exceeds 1 MB
4:@db_name mw3: SELECT total_size_in_bytes > 3 * 1024 * 1024 AS all_workers_counted FROM diskquota.show_cluster_quota_view;

-- === enforcement is per-database ===
2:@db_name mw1: SELECT diskquota.set_schema_quota('public', '1 MB');
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail: mw1's schema quota bites
2:@db_name mw1: INSERT INTO t1 SELECT generate_series(1, 100);
-- expect success: same schema name, different database
3:@db_name mw2: INSERT INTO t2 SELECT generate_series(1, 100);
2:@db_name mw1: SELECT diskquota.set_schema_quota('public', '-1');
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
-- expect success: the deleted quota stops biting
2:@db_name mw1: INSERT INTO t1 SELECT generate_series(1, 100);

-- === one database's dispatch never disturbs another's segment ===
-- === entries                                                  ===
-- Pause mw2's worker so nothing on the mw2 side can rewrite its
-- segment state, then plant an mw2 entry on seg0 directly through
-- refresh_rejectmap() (the test_rejectmap idiom; the epoch advances
-- even while paused). CAST() instead of the usual cast operator:
-- the isolation2 parser forbids colons in a session line that
-- carries a db_name.
3:@db_name mw2: SELECT diskquota.pause();
3:@db_name mw2: SELECT diskquota.wait_for_worker_new_epoch();
3:@db_name mw2: SELECT diskquota.refresh_rejectmap(CAST(ARRAY[ROW((SELECT oid FROM pg_namespace WHERE nspname = 'public'), (SELECT oid FROM pg_database WHERE datname = current_database()), 0, 0, false)] AS diskquota.rejectmap_entry[]), CAST(ARRAY[(SELECT oid FROM pg_class WHERE relname = 't2')] AS oid[])) FROM gp_dist_random('gp_id') WHERE gp_segment_id = 0;
3:@db_name mw2: SELECT count(*) > 0 AS mw2_entry_planted FROM gp_dist_random('diskquota.rejectmap') WHERE dbnode = (SELECT oid FROM pg_database WHERE datname = 'mw2');
-- churn mw1: a full dispatch (quota set while over usage) and a
-- removal dispatch (quota deleted) both replace segment state for
-- mw1 alone
2:@db_name mw1: SELECT diskquota.set_schema_quota('public', '1 MB');
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mw1: SELECT diskquota.set_schema_quota('public', '-1');
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
2:@db_name mw1: SELECT diskquota.wait_for_worker_new_epoch();
-- the planted mw2 entry survived mw1's dispatches
2:@db_name mw1: SELECT count(*) > 0 AS mw2_entry_survived FROM gp_dist_random('diskquota.rejectmap') WHERE dbnode = (SELECT oid FROM pg_database WHERE datname = 'mw2');
-- ...and leaves with its owner: unmonitoring mw2 purges its segment
-- entries even though its worker is paused
3:@db_name mw2: DROP EXTENSION diskquota;
2:@db_name mw1: SELECT count(*) AS mw2_entries_after_drop FROM gp_dist_random('diskquota.rejectmap') WHERE dbnode = (SELECT oid FROM pg_database WHERE datname = 'mw2');

-- cleanup
2:@db_name mw1: DROP EXTENSION diskquota;
4:@db_name mw3: DROP EXTENSION diskquota;
2q:
3q:
4q:
-- the terminated workers release their sessions asynchronously
!\retcode for i in $(seq 1 30); do psql -d isolation2test -Atc "DROP DATABASE mw1" >/dev/null 2>&1 && break; sleep 1; done;
!\retcode for i in $(seq 1 30); do psql -d isolation2test -Atc "DROP DATABASE mw2" >/dev/null 2>&1 && break; sleep 1; done;
!\retcode for i in $(seq 1 30); do psql -d isolation2test -Atc "DROP DATABASE mw3" >/dev/null 2>&1 && break; sleep 1; done;

!\retcode gpconfig -c "diskquota.hard_limit" -v "off" > /dev/null;
!\retcode gpstop -u > /dev/null;
