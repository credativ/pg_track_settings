SET search_path = '';
SET timezone TO 'Europe/Paris';
CREATE SCHEMA "PGTS";
-- Extension should be installable in a custom schema
CREATE EXTENSION pg_track_settings WITH SCHEMA "PGTS";
-- But not relocatable
ALTER EXTENSION pg_track_settings SET SCHEMA public;

-- Check the relations that aren't dumped
WITH ext AS (
    SELECT c.oid, c.relname
    FROM pg_depend d
    JOIN pg_extension e ON d.refclassid = 'pg_extension'::regclass
        AND e.oid = d.refobjid
        AND e.extname = 'pg_track_settings'
    JOIN pg_class c ON d.classid = 'pg_class'::regclass
        AND c.oid = d.objid
),
dmp AS (
    SELECT unnest(extconfig) AS oid
    FROM pg_extension
    WHERE extname = 'pg_track_settings'
)
SELECT ext.relname
FROM ext
LEFT JOIN dmp USING (oid)
WHERE dmp.oid IS NULL
ORDER BY ext.relname::text COLLATE "C";

-- Check that all objects are stored in the expected schema
WITH ext AS (
    SELECT pg_describe_object(d.classid, d.objid, d.objsubid) AS descr
    FROM pg_depend d
    JOIN pg_extension e ON d.refclassid = 'pg_extension'::regclass
        AND e.oid = d.refobjid
        AND e.extname = 'pg_track_settings'
)
SELECT descr FROM ext
WHERE descr NOT like '%"PGTS".%'
ORDER BY descr COLLATE "C";

-- test main config history
SELECT COUNT(*) FROM "PGTS".pg_track_settings_history;
SET work_mem = '10MB';
SELECT * FROM "PGTS".pg_track_settings_snapshot();
SELECT pg_catalog.pg_sleep(1);
SET work_mem = '5MB';
SELECT * FROM "PGTS".pg_track_settings_snapshot();
SELECT name, setting_exists, setting, setting_pretty FROM "PGTS".pg_track_settings_log('work_mem') ORDER BY ts ASC;
SELECT name, from_setting, from_exists, to_setting, to_exists, from_setting_pretty, to_setting_pretty FROM "PGTS".pg_track_settings_diff(now() - interval '500 ms', now());
-- test pg_db_role_settings
ALTER DATABASE postgres SET work_mem = '1MB';
SELECT * FROM "PGTS".pg_track_settings_snapshot();
ALTER ROLE postgres SET work_mem = '2MB';
SELECT * FROM "PGTS".pg_track_settings_snapshot();
ALTER ROLE postgres IN DATABASE postgres SET work_mem = '3MB';
SELECT * FROM "PGTS".pg_track_settings_snapshot();
SELECT * FROM "PGTS".pg_track_settings_snapshot();
SELECT COALESCE(datname, '-') AS datname, setrole::regrole, name, setting_exists, setting FROM "PGTS".pg_track_db_role_settings_log('work_mem') s LEFT JOIN pg_database d ON d.oid = s.setdatabase ORDER BY ts ASC;
SELECT COALESCE(datname, '-') AS datname, setrole::regrole, name, from_setting, from_exists, to_setting, to_exists FROM "PGTS".pg_track_db_role_settings_diff(now() - interval '10 min', now()) s LEFT JOIN pg_database d ON d.oid = s.setdatabase WHERE name = 'work_mem' ORDER BY 1, 2, 3;
ALTER DATABASE postgres RESET work_mem;
SELECT * FROM "PGTS".pg_track_settings_snapshot();
ALTER ROLE postgres RESET work_mem;
SELECT * FROM "PGTS".pg_track_settings_snapshot();
ALTER ROLE postgres IN DATABASE postgres RESET work_mem;
SELECT * FROM "PGTS".pg_track_settings_snapshot();
-- test pg_reboot
SELECT COUNT(*) FROM "PGTS".pg_reboot;
SELECT now() - ts > interval '2 second' FROM "PGTS".pg_reboot;
SELECT now() - ts > interval '2 second' FROM "PGTS".pg_track_reboot_log();
-- test the reset
SELECT * FROM "PGTS".pg_track_settings_reset();
SELECT COUNT(*) FROM "PGTS".pg_track_settings_history;
SELECT COUNT(*) FROM "PGTS".pg_track_settings_log('work_mem');
SELECT COUNT(*) FROM "PGTS".pg_track_settings_diff(now() - interval '1 hour', now());
SELECT COUNT(*) FROM "PGTS".pg_track_db_role_settings_log('work_mem');
SELECT COUNT(*) FROM "PGTS".pg_track_db_role_settings_diff(now() - interval '1 hour', now());
SELECT COUNT(*) FROM "PGTS".pg_reboot;
--------------------------
-- test remote snapshot --
--------------------------
-- fake general settings
INSERT INTO "PGTS".pg_track_settings_settings_src_tmp
  (srvid, ts, name, setting, current_setting)
VALUES
(1, '2019-01-01 00:00:00 CET', 'work_mem', '0', '0MB');
-- fake rds settings
INSERT INTO "PGTS".pg_track_settings_rds_src_tmp
  (srvid, ts, name, setting, setdatabase, setrole)
VALUES
(1, '2019-01-01 00:00:00 CET', 'work_mem', '0MB', 123, 0);
-- fake reboot settings
INSERT INTO "PGTS".pg_track_settings_reboot_src_tmp
  (srvid, ts, postmaster_ts)
VALUES
(1, '2019-01-01 00:01:00 CET', '2019-01-01 00:00:00 CET');

SELECT "PGTS".pg_track_settings_snapshot_settings(1);
SELECT "PGTS".pg_track_settings_snapshot_rds(1);
SELECT "PGTS".pg_track_settings_snapshot_reboot(1);

-- fake general settings
INSERT INTO "PGTS".pg_track_settings_settings_src_tmp
  (srvid, ts, name, setting, current_setting)
VALUES
-- previously untreated data that should be discarded
(1, '2019-01-02 00:00:00 CET', 'work_mem', '5120', '5MB'),
-- data that should be processed
(1, '2019-01-02 01:00:00 CET', 'work_mem', '10240', '10MB'),
(1, '2019-01-02 01:00:00 CET', 'something', 'someval', 'someval');
-- fake rds settings
INSERT INTO "PGTS".pg_track_settings_rds_src_tmp
  (srvid, ts, name, setting, setdatabase, setrole)
VALUES
-- previously untreated data that should be discarded
(1, '2019-01-02 00:00:00 CET', 'work_mem', '5MB', 123, 0),
-- data that should be processed
(1, '2019-01-02 01:00:00 CET', 'work_mem', '10MB', 123, 0),
(1, '2019-01-02 01:00:00 CET', 'something', 'someval', 0, 456);
-- fake reboot settings
INSERT INTO "PGTS".pg_track_settings_reboot_src_tmp
  (srvid, ts, postmaster_ts)
VALUES
-- previously untreated data that should not be discarded
(1, '2019-01-02 00:01:00 CET', '2019-01-02 00:00:00 CET'),
-- data that should also be processed
(1, '2019-01-02 02:01:00 CET', '2019-01-02 01:00:00 CET');
SELECT "PGTS".pg_track_settings_snapshot_settings(1);
SELECT "PGTS".pg_track_settings_snapshot_rds(1);
SELECT "PGTS".pg_track_settings_snapshot_reboot(1);
-- test raw data
SELECT * FROM "PGTS".pg_track_settings_list ORDER BY 1, 2;
SELECT * FROM "PGTS".pg_track_settings_history ORDER BY 1, 2, 3;
SELECT * FROM "PGTS".pg_track_db_role_settings_list ORDER BY 1, 2;
SELECT * FROM "PGTS".pg_track_db_role_settings_history ORDER BY 1, 2, 3;
SELECT * FROM "PGTS".pg_reboot ORDER BY 1, 2;

-- test functions
SELECT name, setting_exists, setting, setting_pretty
  FROM "PGTS".pg_track_settings_log('work_mem', 1)
  ORDER BY ts ASC;
SELECT name, from_setting, from_exists, to_setting, to_exists,
  from_setting_pretty, to_setting_pretty
FROM "PGTS".pg_track_settings_diff('2019-01-01 01:00:00 CET',
    '2019-01-02 02:00:00 CET', 1);
SELECT *
FROM "PGTS".pg_track_db_role_settings_log('work_mem', 1) s
ORDER BY ts ASC;
SELECT *
FROM "PGTS".pg_track_db_role_settings_diff('2018-12-31 02:00:00 CET',
    '2019-01-02 03:00:00 CET', 1) s
WHERE name = 'work_mem' ORDER BY 1, 2, 3;
SELECT * FROM "PGTS".pg_track_reboot_log(1);
-- check that all data have been deleted after processing
SELECT COUNT(*) FROM "PGTS".pg_track_settings_settings_src_tmp;
SELECT COUNT(*) FROM "PGTS".pg_track_settings_rds_src_tmp;
SELECT COUNT(*) FROM "PGTS".pg_track_settings_reboot_src_tmp;
-- test the reset
SELECT * FROM "PGTS".pg_track_settings_reset(1);
SELECT COUNT(*) FROM "PGTS".pg_track_settings_history;
SELECT COUNT(*) FROM "PGTS".pg_track_settings_log('work_mem', 1);
SELECT COUNT(*) FROM "PGTS".pg_track_settings_diff('-infinity', 'infinity', 1);
SELECT COUNT(*) FROM "PGTS".pg_track_db_role_settings_log('work_mem', 1);
SELECT COUNT(*) FROM "PGTS".pg_track_db_role_settings_diff('-infinity', 'infinity', 1);
SELECT COUNT(*) FROM "PGTS".pg_reboot;
