\c
-- Remove the 2.4-only quotas through the API while 2.4 is still
-- loaded: the 2.3 worker must never see quota_config rows with
-- quotatype > 4. (The 2.4--2.3 DDL script also deletes such rows as
-- a safety net, but it can only run after the binary flip, and by
-- then a leftover row would already reach the 2.3 worker.)
select diskquota.set_database_quota(current_database()::text, '-1');
set client_min_messages = error;
select diskquota.set_cluster_quota('-1');
reset client_min_messages;
select count(*) as new_scope_rows_before_flip from diskquota.quota_config where quotatype in (5, 6);

\! gpconfig -c shared_preload_libraries -v 'diskquota-2.3.so' > /dev/null
\! gpstop -raf > /dev/null

\! gpconfig -s 'shared_preload_libraries'

\c
alter extension diskquota update to '2.3';
\! sleep 5
