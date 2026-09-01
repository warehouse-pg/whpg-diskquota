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
-- === an error inside the dropped-database reaper is tolerated ===
-- the reaper runs on every launcher loop pass; an error escaping it
-- would take the launcher down with no top-level handler to catch it
SELECT gp_inject_fault('diskquota_reap_dropped_databases', 'error', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
-- the launcher hits the fault on its next pass
SELECT gp_wait_until_triggered_fault('diskquota_reap_dropped_databases', 1, dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
-- the launcher survived: it still answers a round trip
SELECT diskquota.set_cluster_quota('-1');
SELECT diskquota.wait_for_worker_new_epoch();
SELECT gp_inject_fault('diskquota_reap_dropped_databases', 'reset', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;

-- === a worker whose binding is gone exits and frees its slot ===
-- the launcher restart above lost the process-local termination
-- handles, so this DROP cannot signal the worker: it must notice the
-- released binding itself and exit, or it would loop forever and pin
-- its worker slot, starving any later CREATE EXTENSION
DROP EXTENSION diskquota;
\! for i in $(seq 1 30); do n=$(pgrep -fc "bgworker: \[diskquota\] [c]ontrib_regression" || true); [ "$n" = "0" ] && { echo WORKER-EXITED; break; }; sleep 1; done
-- the freed slot serves a new extension
CREATE EXTENSION diskquota;
\! for i in $(seq 1 30); do e=$(psql -d contrib_regression -Atc "select diskquota.show_worker_epoch()" 2>/dev/null); [ -n "$e" ] && [ "$e" != "0" ] && { echo NEW-WORKER-SERVING; break; }; sleep 1; done

-- remove the spent fault entry so a rerun can inject again
SELECT gp_inject_fault('diskquota_launcher_main', 'reset', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
