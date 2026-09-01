CREATE DATABASE db_insert_after_drop;
\c db_insert_after_drop
CREATE EXTENSION diskquota;
-- Test Drop Extension
CREATE SCHEMA sdrtbl;
SELECT diskquota.set_schema_quota('sdrtbl', '1 MB');
SET search_path TO sdrtbl;
CREATE TABLE a(i int) DISTRIBUTED BY (i);
INSERT INTO a SELECT generate_series(1,100);
-- soft limit checks usage before the write, so this insert still
-- succeeds; it is what pushes the schema over its 1 MB quota
INSERT INTO a SELECT generate_series(1,100000);
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.wait_for_worker_new_epoch();
-- expect insert fail: the worker has seen the overage by now
INSERT INTO a SELECT generate_series(1,100);
DROP EXTENSION diskquota;
-- Enforcement is torn down by the launcher asynchronously, and the
-- extension's wait function is gone with the extension: poll the
-- teardown's observable effect -- a probe write succeeding -- with a
-- bounded retry. If it never succeeds, fall through: the visible
-- insert below then fails with the real error.
DO $$
BEGIN
  FOR i IN 1..60 LOOP
    BEGIN
      INSERT INTO sdrtbl.a VALUES (0);
      RETURN;
    EXCEPTION WHEN OTHERS THEN
      PERFORM pg_sleep(0.5);
    END;
  END LOOP;
END $$;
-- expect insert success: the dropped extension no longer enforces
INSERT INTO a SELECT generate_series(1,100);
DROP TABLE a;
\c postgres
-- the terminated worker releases its session asynchronously
\! for i in $(seq 1 30); do psql -d postgres -Atc "DROP DATABASE db_insert_after_drop" >/dev/null 2>&1 && break; sleep 1; done
SELECT count(*) FROM pg_database WHERE datname = 'db_insert_after_drop';
