-- A launcher restart replays the monitored-database registration
-- (init_database_list -> ADD_DB_TO_MONITOR) for every database in
-- database_list, with shared memory intact. The replayed ADD must not
-- reset an existing cache entry: the worker publishes DB_RUNNING only
-- when it transitions to inited, so a clobbered status would report
-- the database as "counted as 0 until initialized" forever, and a
-- zeroed epoch would confuse concurrent wait_for_worker_new_epoch()
-- callers.
SELECT diskquota.wait_for_worker_new_epoch();
-- error out the launcher once; the postmaster restarts it after
-- BGW_DEFAULT_RESTART_INTERVAL (60s) with shared memory intact
SELECT gp_inject_fault('diskquota_launcher_main', 'error', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
\! sleep 75
-- the restarted launcher must serve requests again, and the replayed
-- registration must have kept the worker's bookkeeping
SELECT diskquota.wait_for_worker_new_epoch();
-- expect only the (matchsubs-normalized) unmonitored warning; the
-- "counted as 0 until initialized" warning must NOT appear: the
-- replay kept this database's status
CREATE DATABASE lr_scratch;
SELECT diskquota.set_cluster_quota('10 MB');
DROP DATABASE lr_scratch;
SELECT diskquota.set_cluster_quota('-1');
-- remove the spent fault entry so a rerun can inject again
SELECT gp_inject_fault('diskquota_launcher_main', 'reset', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
