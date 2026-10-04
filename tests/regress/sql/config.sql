--start_ignore
CREATE DATABASE diskquota;

\! gpconfig -c shared_preload_libraries -v $(./data/current_binary_name);
\! gpconfig -c diskquota.naptime -v 0 --skipvalidation
\! gpconfig -c max_worker_processes -v 20 --skipvalidation
\! gpconfig -c diskquota.hard_limit -v "off" --skipvalidation
\! gpconfig -c diskquota.max_workers -v 1 --skipvalidation
-- 180 s, not the 60 s default: test_extension and test_worker_schedule wait
-- for worker epochs some thirty times each while max_workers = 1 cycles a
-- dozen databases, so one wait can take a full launcher round, and a slow CI
-- runner pushed that past 60 s on WHPG19 (whpg-extensions-packaging#122 run
-- 37202088853). A dead worker still fails, three minutes later.
\! gpconfig -c diskquota.worker_timeout -v 180 --skipvalidation
\! gpconfig -c plpython3.python_path -v "'$GPHOME/lib/python'" --skipvalidation;
\! gpconfig -c log_min_messages -v debug1

\! gpstop -raf
--end_ignore

\c
-- Show the values of all GUC variables
-- start_ignore
SHOW diskquota.naptime;
-- end_ignore
SHOW diskquota.max_active_tables;
SHOW diskquota.worker_timeout;
SHOW diskquota.hard_limit;
