\!gpconfig -s 'shared_preload_libraries'

create extension diskquota with version '2.4';
select diskquota.wait_for_worker_new_epoch();

-- schema quota
create schema s1;
select diskquota.set_schema_quota('s1', '1 MB');
create table s1.a(i int) distributed by (i);
insert into s1.a select generate_series(1, 10000000); -- ok.

-- role quota
create schema srole;
create role u1 nologin;
create table srole.b (t text) distributed by (t);
alter table srole.b owner to u1;
select diskquota.set_role_quota('u1', '1 MB');
insert into srole.b select generate_series(1,100000); -- ok.

-- schema tablespace quota
\! mkdir -p /tmp/schemaspc
create schema spcs1;
create tablespace schemaspc location '/tmp/schemaspc';
select diskquota.set_schema_tablespace_quota('spcs1', 'schemaspc','1 MB');
create table spcs1.a(i int) tablespace schemaspc distributed by (i);
insert into spcs1.a select generate_series(1,100000); -- ok.

-- role tablespace quota
\! mkdir -p /tmp/rolespc
create tablespace rolespc location '/tmp/rolespc';
create role rolespcu1 nologin;
create schema rolespcrole;
create table rolespcrole.b (t text) tablespace rolespc distributed by (t);
alter table rolespcrole.b owner to rolespcu1;
select diskquota.set_role_tablespace_quota('rolespcu1', 'rolespc', '1 MB');
insert into rolespcrole.b select generate_series(1,100000); -- ok.

-- 2.4-only scopes: a database quota and a cluster quota. Large caps,
-- so they never interfere with the per-type tests above; in the
-- downgrade schedule their job is to leave quota_config rows behind
-- for the downgrade DDL script to clean up.
select diskquota.set_database_quota(current_database()::text, '10 GB');
-- the unmonitored-databases warning depends on which other databases
-- exist in the cluster; silence it
set client_min_messages = error;
select diskquota.set_cluster_quota('20 GB');
reset client_min_messages;
select quota_in_mb from diskquota.show_database_quota_view;
select quota_in_mb from diskquota.show_cluster_quota_view;
select count(*) as new_scope_rows from diskquota.quota_config where quotatype in (5, 6);

\!sleep 5

-- leaked resource:
-- 		role u1, rolespcu1
-- 		table s1.a, srole.b spcs1.a, rolespcrole.b
-- 		schema s1, srole, spcs1, rolespcrole
--		tablespace schemaspc, rolespc
