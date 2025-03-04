-- start_ignore
DROP VIEW IF EXISTS cancel_all;
DROP ROLE IF EXISTS role1_cpu_test;
DROP ROLE IF EXISTS role2_cpu_test;
DROP RESOURCE GROUP rg1_cpu_test;
DROP RESOURCE GROUP rg2_cpu_test;

CREATE LANGUAGE plpython3u;
-- end_ignore

--
-- helper functions, tables and views
--

DROP TABLE IF EXISTS cpu_usage_samples;
CREATE TABLE cpu_usage_samples (sample text);

-- fetch_sample: select cpu_usage from gp_toolkit.gp_resgroup_status
-- and dump them into text in json format then save them in db for
-- further analysis.
CREATE OR REPLACE FUNCTION fetch_sample() RETURNS text AS $$
    import json

    group_cpus = plpy.execute('''
        SELECT groupname, cpu_usage FROM gp_toolkit.gp_resgroup_status_per_host
    ''')
    plpy.notice(group_cpus)
    json_text = json.dumps(dict([(row['groupname'], float(row['cpu_usage'])) for row in group_cpus]))
    plpy.execute('''
        INSERT INTO cpu_usage_samples VALUES ('{value}')
    '''.format(value=json_text))
    return json_text
$$ LANGUAGE plpython3u;

-- verify_cpu_usage: calculate each QE's average cpu usage using all the data in
-- the table cpu_usage_sample. And compare the average value to the expected value.
-- return true if the practical value is close to the expected value.
CREATE OR REPLACE FUNCTION verify_cpu_usage(groupname TEXT, expect_cpu_usage INT, err_rate INT)
RETURNS BOOL AS $$
    import json
    import functools

    all_info = plpy.execute('''
        SELECT sample::json->'{name}' AS cpu FROM cpu_usage_samples
    '''.format(name=groupname))
    usage = float(all_info[0]['cpu'])

    return abs(usage - expect_cpu_usage) <= err_rate
$$ LANGUAGE plpython3u;

CREATE OR REPLACE FUNCTION busy() RETURNS void AS $$
    import os
    import signal

    n = 15
    for i in range(n):
        if os.fork() == 0:
			# children must quit without invoking the atexit hooks
            signal.signal(signal.SIGINT,  lambda a, b: os._exit(0))
            signal.signal(signal.SIGQUIT, lambda a, b: os._exit(0))
            signal.signal(signal.SIGTERM, lambda a, b: os._exit(0))

            # generate pure cpu load
            while True:
                pass

    os.wait()
$$ LANGUAGE plpython3u;

CREATE VIEW cancel_all AS
    SELECT pg_cancel_backend(pid)
    FROM pg_stat_activity
    WHERE query LIKE 'SELECT * FROM % WHERE busy%';

-- create two resource groups
CREATE RESOURCE GROUP rg1_cpu_test WITH (concurrency=5, cpu_hard_quota_limit=-1, cpu_soft_priority=100);
CREATE RESOURCE GROUP rg2_cpu_test WITH (concurrency=5, cpu_hard_quota_limit=-1, cpu_soft_priority=200);

--
-- check gpdb cgroup configuration
-- The implementation of check_cgroup_configuration() is in resgroup_auxiliary_tools_*.sql
--
select check_cgroup_configuration();

-- lower admin_group's cpu_hard_quota_limit to minimize its side effect
ALTER RESOURCE GROUP admin_group SET cpu_hard_quota_limit 1;

-- create two roles and assign them to above groups
CREATE ROLE role1_cpu_test RESOURCE GROUP rg1_cpu_test;
CREATE ROLE role2_cpu_test RESOURCE GROUP rg2_cpu_test;
GRANT ALL ON FUNCTION busy() TO role1_cpu_test;
GRANT ALL ON FUNCTION busy() TO role2_cpu_test;

-- prepare parallel queries in the two groups
10: SET ROLE TO role1_cpu_test;
11: SET ROLE TO role1_cpu_test;
12: SET ROLE TO role1_cpu_test;
13: SET ROLE TO role1_cpu_test;
14: SET ROLE TO role1_cpu_test;

20: SET ROLE TO role2_cpu_test;
21: SET ROLE TO role2_cpu_test;
22: SET ROLE TO role2_cpu_test;
23: SET ROLE TO role2_cpu_test;
24: SET ROLE TO role2_cpu_test;

--
-- now we get prepared.
--
-- on empty load the cpu usage shall be 0%
--

10&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
11&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
12&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
13&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
14&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;

-- start_ignore
-- Gather CPU usage statistics into cpu_usage_samples
TRUNCATE TABLE cpu_usage_samples;
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
TRUNCATE TABLE cpu_usage_samples;
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
-- end_ignore

SELECT verify_cpu_usage('rg1_cpu_test', 90, 10);

-- start_ignore
SELECT * FROM cancel_all;

10<:
11<:
12<:
13<:
14<:
-- end_ignore

10q:
11q:
12q:
13q:
14q:

10: SET ROLE TO role1_cpu_test;
11: SET ROLE TO role1_cpu_test;
12: SET ROLE TO role1_cpu_test;
13: SET ROLE TO role1_cpu_test;
14: SET ROLE TO role1_cpu_test;

--
-- when there are multiple groups with parallel queries,
-- they should share the cpu usage by their cpu_soft_priority settings,
--
-- rg1_cpu_test:rg2_cpu_test is 100:200 => 1:2, so:
--
-- - rg1_cpu_test gets 90% * 1/3 => 30%;
-- - rg2_cpu_test gets 90% * 2/3 => 60%;
--

10&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
11&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
12&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
13&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
14&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;

20&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
21&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
22&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
23&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
24&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;

-- start_ignore
TRUNCATE TABLE cpu_usage_samples;
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
TRUNCATE TABLE cpu_usage_samples;
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
SELECT fetch_sample();
SELECT pg_sleep(1.7);
-- end_ignore

SELECT verify_cpu_usage('rg1_cpu_test', 30, 10);
SELECT verify_cpu_usage('rg2_cpu_test', 60, 10);

-- start_ignore
SELECT * FROM cancel_all;

10<:
11<:
12<:
13<:
14<:

20<:
21<:
22<:
23<:
24<:

10q:
11q:
12q:
13q:
14q:


20q:
21q:
22q:
23q:
24q:
-- end_ignore



-- Test hard quota limit
ALTER RESOURCE GROUP rg1_cpu_test set cpu_hard_quota_limit 10;
ALTER RESOURCE GROUP rg2_cpu_test set cpu_hard_quota_limit 20;

-- prepare parallel queries in the two groups
10: SET ROLE TO role1_cpu_test;
11: SET ROLE TO role1_cpu_test;
12: SET ROLE TO role1_cpu_test;
13: SET ROLE TO role1_cpu_test;
14: SET ROLE TO role1_cpu_test;

20: SET ROLE TO role2_cpu_test;
21: SET ROLE TO role2_cpu_test;
22: SET ROLE TO role2_cpu_test;
23: SET ROLE TO role2_cpu_test;
24: SET ROLE TO role2_cpu_test;

--
-- now we get prepared.
--
-- on empty load the cpu usage shall be 0%
--
--
-- a group should not burst to use all the cpu usage
-- when it's the only one with running queries.
--
-- so the cpu usage shall be 10%
--

10&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
11&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
12&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
13&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
14&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;

-- start_ignore
1:TRUNCATE TABLE cpu_usage_samples;
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:TRUNCATE TABLE cpu_usage_samples;
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
-- end_ignore

-- verify it
1:SELECT verify_cpu_usage('rg1_cpu_test', 10, 2);

-- start_ignore
1:SELECT * FROM cancel_all;

10<:
11<:
12<:
13<:
14<:
-- end_ignore

10q:
11q:
12q:
13q:
14q:

10: SET ROLE TO role1_cpu_test;
11: SET ROLE TO role1_cpu_test;
12: SET ROLE TO role1_cpu_test;
13: SET ROLE TO role1_cpu_test;
14: SET ROLE TO role1_cpu_test;

--
-- when there are multiple groups with parallel queries,
-- they should follow the enforcement of the cpu usage.
--
-- rg1_cpu_test:rg2_cpu_test is 10:20, so:
--
-- - rg1_cpu_test gets 10%;
-- - rg2_cpu_test gets 20%;
--

10&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
11&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
12&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
13&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
14&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;

20&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
21&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
22&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
23&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;
24&: SELECT * FROM gp_dist_random('gp_id') WHERE busy() IS NULL;

-- start_ignore
1:TRUNCATE TABLE cpu_usage_samples;
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:TRUNCATE TABLE cpu_usage_samples;
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
1:SELECT fetch_sample();
1:SELECT pg_sleep(1.7);
-- end_ignore

1:SELECT verify_cpu_usage('rg1_cpu_test', 10, 2);
1:SELECT verify_cpu_usage('rg2_cpu_test', 20, 2);

-- start_ignore
1:SELECT * FROM cancel_all;

10<:
11<:
12<:
13<:
14<:

20<:
21<:
22<:
23<:
24<:

10q:
11q:
12q:
13q:
14q:


20q:
21q:
22q:
23q:
24q:

1q:
-- end_ignore

-- restore admin_group's cpu_hard_quota_limit
2:ALTER RESOURCE GROUP admin_group SET cpu_hard_quota_limit 10;

-- cleanup
2:REVOKE ALL ON FUNCTION busy() FROM role1_cpu_test;
2:REVOKE ALL ON FUNCTION busy() FROM role2_cpu_test;
2:DROP ROLE role1_cpu_test;
2:DROP ROLE role2_cpu_test;
2:DROP RESOURCE GROUP rg1_cpu_test;
2:DROP RESOURCE GROUP rg2_cpu_test;
