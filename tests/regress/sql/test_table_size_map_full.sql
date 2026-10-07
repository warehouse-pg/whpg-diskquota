-- Each monitored database keeps its table sizes in its own shared-memory
-- hash (table_size_map), sized to its share of diskquota.max_table_segments:
-- MAX_NUM_TABLE_SIZE_ENTRIES_PER_DB = max_table_segments / 100 /
-- max_monitored_databases + 100 entries. Two things must hold:
--
--  * several databases can be monitored at once - each gets its own map
--    out of the reserved memory (a map requesting more than its share
--    would leave nothing for the next database);
--  * a database with more tables than its share degrades gracefully: on
--    servers where the map is a hard cap the overflow stays untracked, but
--    the tracked tables keep being refreshed and enforced, and the other
--    databases are unaffected. An error on every refresh cycle instead
--    would freeze all quotas of the overflowing database.
--
-- 131072 segments => 1310 entries, / 50 databases + 100 => a share of 126
-- entries; 200 extra tables overflow it.

-- start_ignore
\! gpconfig -c diskquota.max_table_segments -v 131072 --skipvalidation
\! gpconfig -c diskquota.max_monitored_databases -v 50 --skipvalidation
\! gpstop -ari
-- end_ignore

\c

-- a second monitored database, with a quota of its own
CREATE DATABASE tsmf_db2;
\c tsmf_db2
CREATE EXTENSION diskquota;
CREATE SCHEMA q;
CREATE TABLE q.t(i int) DISTRIBUTED BY (i);
SELECT diskquota.set_schema_quota('q', '1 MB');
SELECT diskquota.wait_for_worker_new_epoch();

\c contrib_regression
CREATE SCHEMA tsmf_quota;
CREATE TABLE tsmf_quota.big(i int) DISTRIBUTED BY (i);
SELECT diskquota.set_schema_quota('tsmf_quota', '1 MB');
SELECT diskquota.wait_for_worker_new_epoch();

-- overflow this database's share
CREATE SCHEMA tsmf_fill;
DO $$
BEGIN
	FOR i IN 1..200 LOOP
		EXECUTE format('CREATE TABLE tsmf_fill.t%s (i int) DISTRIBUTED BY (i)', i);
	END LOOP;
END
$$;
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.wait_for_worker_new_epoch();

-- the table that was tracked before the overflow is still refreshed:
-- loading it past its schema quota is noticed
INSERT INTO tsmf_quota.big SELECT generate_series(1, 200000);
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail
INSERT INTO tsmf_quota.big VALUES (1);

-- the other database is unaffected by the overflow here
\c tsmf_db2
INSERT INTO q.t SELECT generate_series(1, 200000);
SELECT diskquota.wait_for_worker_new_epoch();
SELECT diskquota.wait_for_worker_new_epoch();
-- expect fail
INSERT INTO q.t VALUES (1);

-- cleanup
SELECT diskquota.set_schema_quota('q', '-1');
SELECT diskquota.wait_for_worker_new_epoch();
DROP EXTENSION diskquota;
\c contrib_regression
SELECT diskquota.set_schema_quota('tsmf_quota', '-1');
SELECT diskquota.wait_for_worker_new_epoch();
DROP TABLE tsmf_quota.big;
DROP SCHEMA tsmf_quota;
SET client_min_messages = warning;
DROP SCHEMA tsmf_fill CASCADE;
RESET client_min_messages;
SELECT diskquota.wait_for_worker_new_epoch();
DROP DATABASE tsmf_db2;

-- start_ignore
\! gpconfig -r diskquota.max_table_segments
\! gpconfig -r diskquota.max_monitored_databases
\! gpstop -ari
-- end_ignore
