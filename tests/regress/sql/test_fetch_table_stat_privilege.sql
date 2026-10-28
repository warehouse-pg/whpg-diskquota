-- diskquota_fetch_table_stat() is dispatched to the segments by the diskquota
-- workers to read the active tables and to switch a database's monitoring on
-- and off. It is not for users: the function itself insists on a superuser,
-- whatever its EXECUTE grant.
CREATE ROLE fetch_stat_r NOLOGIN;
GRANT USAGE ON SCHEMA diskquota TO fetch_stat_r;

SET ROLE fetch_stat_r;
SELECT diskquota.diskquota_fetch_table_stat(0, '{}'::oid[]) FROM gp_dist_random('gp_id');
SELECT diskquota.diskquota_fetch_table_stat(0, '{}'::oid[]);
RESET ROLE;

-- The monitor modes take exactly one database oid.
SELECT diskquota.diskquota_fetch_table_stat(5, '{}'::oid[]) FROM gp_dist_random('gp_id');
SELECT diskquota.diskquota_fetch_table_stat(5, '{NULL}'::oid[]) FROM gp_dist_random('gp_id');
SELECT diskquota.diskquota_fetch_table_stat(5, ARRAY[1::oid, 2::oid]) FROM gp_dist_random('gp_id');

REVOKE USAGE ON SCHEMA diskquota FROM fetch_stat_r;
DROP ROLE fetch_stat_r;
