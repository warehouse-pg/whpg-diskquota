-- need run 2.2_set_quota before run this test
-- FIXME add version check here

\! sleep 5

-- the downgrade DDL script must have removed the 2.4-only quota rows;
-- a leftover row (quotatype 5 or 6) would send the 2.3 worker through
-- an out-of-bounds quota_key_num lookup on every refresh
select count(*) as leftover_new_scope_rows from diskquota.quota_config where quotatype in (5, 6);

insert into s1.a select generate_series(1, 10000000); -- fail.
insert into srole.b select generate_series(1, 100000); -- fail.

insert into rolespcrole.b select generate_series(1, 100000); -- fail.
insert into spcs1.a select generate_series(1, 100000); -- fail.

drop table s1.a, srole.b, spcs1.a, rolespcrole.b;
drop schema s1, srole, spcs1, rolespcrole;
drop tablespace rolespc;
drop tablespace schemaspc;
drop role u1, rolespcu1;
