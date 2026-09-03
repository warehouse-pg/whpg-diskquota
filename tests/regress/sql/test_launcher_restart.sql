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

-- === bind-time incarnation fencing ===
-- A worker fences on the slot generation the launcher stamped when it
-- started, not on the live slot value. The slot can be released and
-- re-claimed (new generation) before the worker finishes starting; a
-- worker that read the live value then would adopt an incarnation it
-- was never started for and pass the binding check as if current. To
-- reach that window the launcher must lose the worker's termination
-- handle (a launcher restart), or DROP would just signal the worker
-- directly.
DROP EXTENSION diskquota;
\! for i in $(seq 1 30); do n=$(psql -d contrib_regression -Atc "select count(*) from pg_stat_activity where backend_type like 'diskquota bgworker%'" 2>/dev/null); [ "$n" = "0" ] && { echo WORKER-GONE; break; }; sleep 1; done
-- hold the next worker just before it adopts its incarnation
SELECT gp_inject_fault('diskquota_worker_startup_fence', 'suspend', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
CREATE EXTENSION diskquota;
SELECT gp_wait_until_triggered_fault('diskquota_worker_startup_fence', 1, dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
-- record the held worker's pid from the cluster's own view; the guard
-- below is only meaningful if this actually captured one
\! psql -d contrib_regression -Atc "select pid from pg_stat_activity where backend_type like 'diskquota bgworker%'" > /tmp/dq_fence_pid 2>/dev/null; if [ -s /tmp/dq_fence_pid ] && [ -n "$(cat /tmp/dq_fence_pid)" ]; then echo SUSPENDED-PID-SAVED; else echo NO-SUSPENDED-PID; fi
-- lose the launcher's process-local termination handles
SELECT gp_inject_fault('diskquota_launcher_main', 'error', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
\! sleep 75
-- cancel the held worker's incarnation behind its back: the restarted
-- launcher cannot signal it (NULL handle), and the CREATE re-claims the
-- slot with a new generation
DROP EXTENSION diskquota;
CREATE EXTENSION diskquota;
-- let the held worker run; it must fence itself out on its stamped
-- generation and free the only worker slot for the new incarnation
SELECT gp_inject_fault('diskquota_worker_startup_fence', 'resume', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
SELECT gp_inject_fault('diskquota_worker_startup_fence', 'reset', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
\! p=$(cat /tmp/dq_fence_pid); for i in $(seq 1 60); do kill -0 "$p" 2>/dev/null || { echo STALE-WORKER-FENCED-OUT; break; }; sleep 1; done
\! for i in $(seq 1 60); do e=$(psql -d contrib_regression -Atc "select diskquota.show_worker_epoch()" 2>/dev/null); [ -n "$e" ] && [ "$e" != "0" ] && { echo NEW-INCARNATION-SERVING; break; }; sleep 1; done
SELECT gp_inject_fault('diskquota_launcher_main', 'reset', dbid)
  FROM gp_segment_configuration WHERE role = 'p' AND content = -1;
\! rm -f /tmp/dq_fence_pid
