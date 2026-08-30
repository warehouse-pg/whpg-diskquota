\c
-- Prepare the downgrade while 2.4 is still loaded: the helper removes
-- this database's 2.4-only quota rows (the 2.3 worker must never see
-- quotatype > 4) and drops the cluster cap from the launcher's
-- global_quota_config, which a plain per-database cleanup would leave
-- behind to re-arm on a later upgrade. (The 2.4--2.3 DDL script also
-- deletes leftover rows as a safety net, but it runs after the binary
-- flip -- too late to protect the 2.3 worker's first refresh.)
set client_min_messages = error;
select diskquota.prepare_downgrade();
reset client_min_messages;
select count(*) as new_scope_rows_before_flip from diskquota.quota_config where quotatype in (5, 6);

\! gpconfig -c shared_preload_libraries -v 'diskquota-2.3.so' > /dev/null
\! gpstop -raf > /dev/null

\! gpconfig -s 'shared_preload_libraries'

\c
alter extension diskquota update to '2.3';
\! sleep 5
