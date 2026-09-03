-- remove objects introduced in 2.4
-- A configured cluster quota must be removed while 2.4 is still the
-- loaded library (diskquota.prepare_downgrade() does that): it lives
-- in the launcher's own database, which this script -- running in an
-- arbitrary database, possibly without the 2.4 library -- can neither
-- read nor clean. So the downgrade requires the mark
-- prepare_downgrade() leaves in diskquota.state; along the shipped
-- order (flip shared_preload_libraries first, then ALTER) that mark
-- is the only evidence the cap was cleared, and skipping the
-- preparation would let the cap survive in global_quota_config and
-- silently re-arm on a later upgrade back to 2.4. While the 2.4
-- library is still loaded, a still-configured cap is additionally
-- reported directly.
DO $$
BEGIN
	IF (SELECT state FROM diskquota.state) IS DISTINCT FROM 2 THEN
		RAISE EXCEPTION 'this database is not prepared for downgrade'
		      USING HINT = 'run SELECT diskquota.prepare_downgrade() in every monitored database before downgrading';
	END IF;
	IF current_setting('shared_preload_libraries') LIKE '%diskquota-2.4%' THEN
		IF diskquota.cluster_quota_limit_mb() > 0 THEN
			RAISE EXCEPTION 'a cluster quota is still configured'
			      USING HINT = 'run SELECT diskquota.prepare_downgrade() in every monitored database before downgrading';
		END IF;
	END IF;
END
$$;
-- the mark served its purpose; hand 2.3 a ready state
UPDATE diskquota.state SET state = 1;
-- The 2.3 worker feeds every quota_config row into a lookup indexed
-- by quotatype and only knows types 0..4; a leftover CLUSTER_QUOTA(5)
-- or DATABASE_QUOTA(6) row would make it read past that lookup on
-- every refresh. Delete them before 2.3 can ever see the table.
DELETE FROM diskquota.quota_config WHERE quotatype IN (5, 6);
DROP VIEW IF EXISTS diskquota.show_cluster_quota_view;
DROP VIEW IF EXISTS diskquota.show_database_quota_view;
DROP FUNCTION IF EXISTS diskquota.prepare_downgrade();
DROP FUNCTION IF EXISTS diskquota.set_cluster_quota(text);
DROP FUNCTION IF EXISTS diskquota.set_database_quota(text, text);
DROP FUNCTION IF EXISTS diskquota.cluster_quota_limit_mb();
DROP FUNCTION IF EXISTS diskquota.cluster_total_size();
DROP FUNCTION IF EXISTS diskquota.database_quota_limit_mb();
DROP FUNCTION IF EXISTS diskquota.database_total_size();
-- TODO check if worker should not refresh, current lib should be diskquota-2.3.so

-- UDF
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.set_schema_quota(text, text) RETURNS void STRICT AS '$libdir/diskquota-2.3.so' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.set_role_quota(text, text) RETURNS void STRICT AS '$libdir/diskquota-2.3.so' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.init_table_size_table() RETURNS void STRICT AS '$libdir/diskquota-2.3.so' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.diskquota_fetch_table_stat(int4, oid[]) RETURNS setof diskquota.diskquota_active_table_type AS '$libdir/diskquota-2.3.so', 'diskquota_fetch_table_stat' LANGUAGE C VOLATILE;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.set_schema_tablespace_quota(text, text, text) RETURNS void STRICT AS '$libdir/diskquota-2.3.so' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.set_role_tablespace_quota(text, text, text) RETURNS void STRICT AS '$libdir/diskquota-2.3.so' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.set_per_segment_quota(text, float4) RETURNS void STRICT AS '$libdir/diskquota-2.3.so' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.refresh_rejectmap(diskquota.rejectmap_entry[], oid[]) RETURNS void STRICT AS '$libdir/diskquota-2.3.so' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.show_rejectmap() RETURNS setof diskquota.rejectmap_entry_detail AS '$libdir/diskquota-2.3.so', 'show_rejectmap' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.pause() RETURNS void STRICT AS '$libdir/diskquota-2.3.so', 'diskquota_pause' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.resume() RETURNS void STRICT AS '$libdir/diskquota-2.3.so', 'diskquota_resume' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.show_worker_epoch() RETURNS bigint STRICT AS '$libdir/diskquota-2.3.so', 'show_worker_epoch' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.wait_for_worker_new_epoch() RETURNS boolean STRICT AS '$libdir/diskquota-2.3.so', 'wait_for_worker_new_epoch' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.status() RETURNS TABLE ("name" text, "status" text) STRICT AS '$libdir/diskquota-2.3.so', 'diskquota_status' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.show_relation_cache() RETURNS setof diskquota.relation_cache_detail AS '$libdir/diskquota-2.3.so', 'show_relation_cache' LANGUAGE C;

DROP FUNCTION IF EXISTS diskquota.relation_size(relation regclass);
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.relation_size_local(reltablespace oid, relfilenode oid, relpersistence "char", relstorage "char", relam oid) RETURNS bigint STRICT AS '$libdir/diskquota-2.3.so', 'relation_size_local' LANGUAGE C;
/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.pull_all_table_size(OUT tableid oid, OUT size bigint, OUT segid smallint) RETURNS SETOF RECORD AS '$libdir/diskquota-2.3.so', 'pull_all_table_size' LANGUAGE C;

CREATE FUNCTION diskquota.relation_size(relation regclass) RETURNS bigint STRICT AS $$
       SELECT SUM(size)::bigint FROM (
               SELECT diskquota.relation_size_local(reltablespace, relfilenode, relpersistence,
		CASE WHEN EXISTS
	(SELECT FROM pg_catalog.pg_attribute WHERE attrelid = 'pg_class'::regclass AND attname = 'relstorage') THEN relstorage::"char" ELSE ''::"char" END,
		relam) AS size
               FROM gp_dist_random('pg_class') as relstorage WHERE oid = relation
               UNION ALL
               SELECT diskquota.relation_size_local(reltablespace, relfilenode, relpersistence,
		CASE WHEN EXISTS
	(SELECT FROM pg_catalog.pg_attribute WHERE attrelid = 'pg_class'::regclass AND attname = 'relstorage') THEN relstorage::"char" ELSE ''::"char" END,
		relam) AS size
               FROM pg_class as relstorage WHERE oid = relation
       ) AS t $$ LANGUAGE SQL;

/* ALTER */ CREATE OR REPLACE FUNCTION diskquota.show_relation_cache_all_seg() RETURNS setof diskquota.relation_cache_detail AS $$
	WITH relation_cache AS (
		SELECT diskquota.show_relation_cache() AS a
		FROM  gp_dist_random('gp_id')
	)
	SELECT (a).* FROM relation_cache; $$ LANGUAGE SQL;
-- UDF end
