-- Tools/perf-bench/sql/seed.sql
-- Seeds chickadee_perf (already migrated by the server) with one course at
-- realistic scale. Requires the users `perfadmin` and `template` and the
-- course STAT231 created through the real routes (setup.sh does both).
-- Deterministic: ids derive from md5 of a label, so the script is re-runnable
-- after a truncate.
\set ON_ERROR_STOP on
\timing on
set synchronous_commit = off;

create temp table ctx as
select (select id from courses where code = 'STAT231') as course_id,
       (select id from users where username = 'template') as instructor_id,
       (select password_hash from users where username = 'template') as pw;

create or replace function pg_temp.u(label text) returns uuid language sql immutable as
$$ select md5(label)::uuid $$;
create or replace function pg_temp.iso(ts timestamptz) returns text language sql immutable as
$$ select to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;

-- ---------------------------------------------------------------- users
insert into users (id, username, password_hash, role, preferred_name, student_id, email, display_name,
                   last_login_at, last_seen_at, url_token, created_at)
select pg_temp.u('stu' || g), 'stu' || lpad(g::text, 3, '0'), (select pw from ctx), 'user',
       'Student ' || g, (20000000 + g)::text, 'stu' || g || '@example.edu', 'Student Number ' || g,
       now() - (g % 7) * interval '1 day', now() - (g % 5) * interval '1 hour',
       substr(md5('tok' || g), 1, 8), now() - interval '70 days'
from generate_series(1, 300) g;

insert into users (id, username, password_hash, role, display_name, url_token, created_at, last_login_at)
select pg_temp.u('ta' || g), 'ta' || g, (select pw from ctx), 'user', 'TA ' || g,
       substr(md5('tatok' || g), 1, 8), now() - interval '70 days', now() - interval '1 day'
from generate_series(1, 4) g;
insert into users (id, username, password_hash, role, display_name, url_token, created_at, last_login_at)
values (pg_temp.u('inst2'), 'inst2', (select pw from ctx), 'user', 'Second Instructor',
        substr(md5('inst2'), 1, 8), now() - interval '70 days', now());

-- ---------------------------------------------------------------- enrollments
insert into course_enrollments (id, user_id, course_id, enrolled_at, role)
select pg_temp.u('enr-stu' || g), pg_temp.u('stu' || g), (select course_id from ctx), now() - interval '65 days', 'student'
from generate_series(1, 300) g;
insert into course_enrollments (id, user_id, course_id, enrolled_at, role)
select pg_temp.u('enr-ta' || g), pg_temp.u('ta' || g), (select course_id from ctx), now() - interval '65 days', 'ta'
from generate_series(1, 4) g;
insert into course_enrollments (id, user_id, course_id, enrolled_at, role)
values (pg_temp.u('enr-inst2'), pg_temp.u('inst2'), (select course_id from ctx), now() - interval '65 days', 'instructor');
-- The admin is enrolled as an instructor too, so instructor pages can be
-- measured with either account.
insert into course_enrollments (id, user_id, course_id, enrolled_at, role)
select pg_temp.u('enr-admin'), id, (select course_id from ctx), now() - interval '65 days', 'instructor'
from users where username = 'perfadmin'
on conflict do nothing;

-- ---------------------------------------------------------------- sections
insert into course_sections (id, name, default_grading_mode, sort_order, course_id, created_at)
select pg_temp.u('sec' || g), 'Unit ' || g, 'worker', g, (select course_id from ctx), now() - interval '65 days'
from generate_series(1, 3) g;

-- ---------------------------------------------------------------- test setups + assignments
-- 12 assignments, 20 suites each (12 public, 5 release, 3 secret), Python,
-- worker-graded, with hints and display names like an authored manifest.
create temp table setups as
select a, 'setup-' || md5('setup' || a) as setup_id,
       json_build_object(
         'schemaVersion', 1, 'gradingMode', 'worker', 'language', 'python', 'languageDeclared', true,
         'requiredFiles', json_build_array('assignment.ipynb'), 'timeLimitSeconds', 30, 'makefile', null,
         'testSuites', (select json_agg(json_build_object(
              'tier', case when t <= 12 then 'public' when t <= 17 then 'release' else 'secret' end,
              'script', lpad(t::text, 2, '0') || '_check_q' || t || '.py',
              'name', 'Question ' || t || ': compute the summary statistic for cohort ' || t,
              'dependsOn', json_build_array(),
              'points', 1 + (t % 3),
              'hint', 'Use the grouped mean and check the denominator for missing values in column ' || t || '.'
            ) order by t) from generate_series(1, 20) t)
       )::text as manifest
from generate_series(1, 12) a;

insert into test_setups (id, manifest, zip_path, notebook_path, course_id, created_at)
select setup_id, manifest, '/tmp/chickadee-perf/setups/' || setup_id || '.zip', null,
       (select course_id from ctx), now() - interval '64 days' + a * interval '4 days'
from setups;

insert into assignments (id, public_id, test_setup_id, title, due_at, visibility, validation_status, sort_order,
                         course_id, slug, section_id, starts_at, created_at)
select pg_temp.u('asg' || a), upper(substr(md5('pub' || a), 1, 6)), setup_id, 'Lab ' || a || ': regression and inference',
       now() - interval '56 days' + a * interval '7 days', 'open', 'passed', a,
       (select course_id from ctx), 'lab-' || a, pg_temp.u('sec' || (1 + (a - 1) / 4)),
       now() - interval '64 days' + a * interval '4 days', now() - interval '64 days' + a * interval '4 days'
from setups;

-- ---------------------------------------------------------------- submissions
-- 5 attempts per student per assignment, spread over the 10 days before
-- each due date (and up to now for the open ones).
create temp table subs as
select 'sub-' || md5('sub' || s || '-' || a || '-' || k) as id,
       s, st.a, k, st.setup_id,
       least(now() - interval '5 minutes',
             now() - interval '56 days' + st.a * interval '7 days' - interval '10 days'
             + (k * 2 - 1) * interval '1 day' + ((s * 37 + st.a * 11 + k * 7) % 1440) * interval '1 minute') as at
from generate_series(1, 300) s, setups st, generate_series(1, 5) k;

insert into submissions (id, test_setup_id, kind, status, worker_id, zip_path, attempt_number, filename, user_id,
                         submitted_at, assigned_at, source_kind)
select id, setup_id, 'student', 'complete', 'runner-' || (s % 6), '/tmp/chickadee-perf/subs/' || id || '.zip', k,
       'assignment.ipynb', pg_temp.u('stu' || s), at, at + interval '3 seconds', 'upload'
from subs;

-- Validation runs (solution + starter) per assignment, as authoring leaves them.
insert into submissions (id, test_setup_id, kind, status, worker_id, zip_path, attempt_number, user_id, submitted_at, assigned_at)
select 'val-' || md5('val' || a || k), setup_id, case when k % 2 = 0 then 'validation' else 'starterValidation' end,
       'complete', 'runner-1', '/tmp/x.zip', 1, (select instructor_id from ctx),
       now() - interval '64 days' + a * interval '4 days' + k * interval '1 hour', null
from setups, generate_series(1, 6) k;

-- ---------------------------------------------------------------- results
-- One worker result per submission; 40 % of attempts also have a browser
-- preview result (notebook flow). Pass count rises with attempt number.
create temp table res as
select 'res-w-' || md5(id) as rid, id as sid, setup_id, s, a, k, at, 'worker' as source,
       least(20, 8 + k * 2 + ((s + a) % 4)) as passed
from subs
union all
select 'res-b-' || md5(id), id, setup_id, s, a, k, at - interval '30 seconds', 'browser',
       least(20, 7 + k * 2 + ((s + a) % 4))
from subs where (s + a + k) % 5 < 2;

insert into results (id, submission_id, source, received_at, earned_points, total_points, pass_count, total_tests)
select rid, sid, source, at + interval '20 seconds',
       passed * 2.0, 40, passed, 20
from res;

insert into result_collections (result_id, collection_json)
select rid, json_build_object(
    'submissionID', sid, 'testSetupID', setup_id, 'attemptNumber', k, 'buildStatus', 'passed',
    'compilerOutput', null,
    'outcomes', (select json_agg(json_build_object(
        'testName', lpad(t::text, 2, '0') || '_check_q' || t || '.py', 'testClass', null,
        'tier', case when t <= 12 then 'public' when t <= 17 then 'release' else 'secret' end,
        'status', case when t <= passed then 'pass' else 'fail' end,
        'shortResult', case when t <= passed then 'passed' else 'expected 3.1416 but got 3.0' end,
        'longResult', case when t <= passed then null else
            'AssertionError: mismatch in column ' || t || E'\n' || repeat('  File "/work/check.py", line 42, in check_value' || E'\n', 6) end,
        'score', case when t <= passed then 1.0 else 0.0 end, 'points', 1 + (t % 3),
        'executionTimeMs', 120 + t, 'memoryUsageBytes', null, 'attemptNumber', k,
        'isFirstPassSuccess', false) order by t) from generate_series(1, 20) t),
    'totalTests', 20, 'passCount', passed, 'failCount', 20 - passed, 'errorCount', 0, 'timeoutCount', 0,
    'executionTimeMs', 4200, 'totalPoints', 40, 'earnedPoints', passed * 2.0, 'warnings', json_build_array(),
    'jobStartedAt', pg_temp.iso(at + interval '4 seconds'), 'runnerVersion', '0.5.40',
    'timestamp', pg_temp.iso(at + interval '20 seconds'))::text
from res;

-- Validation results.
insert into results (id, submission_id, source, received_at, earned_points, total_points, pass_count, total_tests)
select 'res-v-' || md5(id), id, 'worker', submitted_at + interval '20 seconds', 40, 40, 20, 20
from submissions where kind in ('validation', 'starterValidation');
insert into result_collections (result_id, collection_json)
select 'res-v-' || md5(id), '{"submissionID":"' || id || '","testSetupID":"' || test_setup_id
       || '","attemptNumber":1,"buildStatus":"passed","outcomes":[],"totalTests":0,"passCount":0,"failCount":0,'
       || '"errorCount":0,"timeoutCount":0,"executionTimeMs":10,"totalPoints":0,"earnedPoints":0,"warnings":[],'
       || '"runnerVersion":"0.5.40","timestamp":"2026-10-01T00:00:00Z"}'
from submissions where kind in ('validation', 'starterValidation');

-- ---------------------------------------------------------------- diagnostics and metrics
insert into submission_diagnostics (submission_id, test_setup_id, course_id, assignment_id, kind, submitted_at, assigned_at,
    started_at, finished_at, queue_wait_ms, execution_ms, turnaround_ms, final_status, runner_id, runner_version,
    timed_out, exit_code, peak_rss_bytes, wall_clock_ms, child_process_count, stdout_bytes, stderr_bytes,
    free_disk_mb_at_start, free_disk_mb_at_end, workdir_peak_bytes, created_at, updated_at)
select id, setup_id, (select course_id from ctx), pg_temp.u('asg' || a), 'student', at, at + interval '3 seconds',
       at + interval '4 seconds', at + interval '20 seconds', 3000, 16000, 20000, 'complete', 'runner-' || (s % 6), '0.5.40',
       false, 0, 180000000, 16000, 3, 2048, 512, 50000, 49990, 30000000, at, at + interval '20 seconds'
from subs;

insert into job_execution_metrics (id, submission_id, job_id, test_setup_id, course_id, assignment_id, user_id, runner_id,
    kind, attempt_number, enqueued_at, assigned_at, started_at, completed_at, queue_wait_ms, execution_ms,
    total_processing_ms, final_status, tests_passed, tests_failed, tests_errored, tests_timed_out, skipped_count,
    workdir_setup_ms, submission_download_ms, test_setup_acquire_ms, submission_unpack_ms, test_execution_ms,
    free_disk_mb_at_start, free_disk_mb_at_end, workdir_peak_bytes, test_setup_cache_hit, created_at, updated_at)
select pg_temp.u('jem' || id), id, id, setup_id, (select course_id from ctx), pg_temp.u('asg' || a), pg_temp.u('stu' || s),
       'runner-' || (s % 6), 'student', k, at, at + interval '3 seconds', at + interval '4 seconds', at + interval '20 seconds',
       3000, 16000, 20000, 'complete', 15, 5, 0, 0, 0, 20, 40, 5, 10, 15000, 50000, 49990, 30000000, true,
       at, at + interval '20 seconds'
from subs;

-- request_metrics: 400k rows over 30 days (polls, results, pages).
insert into request_metrics (id, method, path, request_kind, status_code, started_at, finished_at, duration_ms, submission_id, worker_id)
select pg_temp.u('rm' || g),
       case when g % 4 = 0 then 'GET' else 'POST' end,
       case g % 8 when 0 then '/api/v1/submissions/sub-x' when 1 then '/api/v1/worker/results'
                  when 2 then '/' when 3 then '/testsetups/x/notebook' else '/api/v1/worker/request' end,
       case g % 8 when 0 then 'api' when 1 then 'result_writeback' when 2 then 'web' when 3 then 'web' else 'job_dispatch' end,
       case when g % 97 = 0 then 500 when g % 11 = 0 then 204 else 200 end,
       now() - (g * 6.48) * interval '1 second', now() - (g * 6.48) * interval '1 second' + interval '40 ms',
       5 + (g % 300), null, case when g % 8 >= 4 then 'runner-' || (g % 6) end
from generate_series(1, 400000) g;

-- audit_log: 150k rows over the term.
insert into audit_log (id, actor_user_id, actor_username, action, target_type, target_id, remote_addr, user_agent, metadata, course_id, created_at)
select pg_temp.u('al' || g), pg_temp.u('stu' || (1 + g % 300)), 'stu' || (1 + g % 300),
       (array['submission.created','user.login','notebook.saved','submission.retest','grade.override','assignment.updated'])[1 + g % 6],
       case when g % 6 in (0, 2) then 'submission' else 'user' end, 'sub-' || md5('t' || g), '10.0.0.' || (g % 250),
       'Mozilla/5.0 (X11; Linux x86_64) Chrome/130', '{"k":"v","n":' || g || '}', (select course_id from ctx),
       now() - (g * 40) * interval '1 second'
from generate_series(1, 150000) g;

-- user_activity_events: 250k rows (debounced activity pings).
insert into user_activity_events (id, user_id, role, created_at)
select pg_temp.u('uae' || g), pg_temp.u('stu' || (1 + g % 300)), 'student', now() - (g * 20) * interval '1 second'
from generate_series(1, 250000) g;

-- sessions: 3k live sessions.
insert into _fluent_sessions (id, key, data, created_at)
select pg_temp.u('sess' || g), encode(sha256(('sess' || g)::bytea), 'base64'),
       jsonb_build_object('CSRFSecret', md5('c' || g), '_APIUserSession', upper(pg_temp.u('stu' || (1 + g % 300))::text)),
       now() - (g % 1000) * interval '1 minute'
from generate_series(1, 3000) g;

-- login_attempts, worker_nonces, runner_snapshots, client_diagnostics
insert into login_attempts (id, scope, attempt_key, occurred_at)
select pg_temp.u('la' || g), 'username', 'stu' || (g % 300), now() - (g * 30) * interval '1 second'
from generate_series(1, 20000) g;
insert into worker_nonces (nonce_key, expires_at)
select md5('nonce' || g), now() + interval '5 minutes' - (g % 600) * interval '1 second'
from generate_series(1, 20000) g;
insert into runner_snapshots (id, runner_id, recorded_at, active_jobs, max_jobs, available_capacity, hostname, runner_version,
                              last_poll_at, last_heartbeat_at, server_assigned_job_count_since_start)
select pg_temp.u('rs' || g), 'runner-' || (g % 6), now() - (g * 15) * interval '1 second', g % 4, 4, 4 - g % 4, 'host' || (g % 6),
       '0.5.40', now() - (g * 15) * interval '1 second', now() - (g * 15) * interval '1 second', g
from generate_series(1, 100000) g;
insert into client_diagnostics (id, user_id, test_setup_id, kind, failed_checks, user_agent, message, created_at)
select pg_temp.u('cd' || g), pg_temp.u('stu' || (1 + g % 300)), (select setup_id from setups where setups.a = 1 + g % 12),
       'kernel_boot_failure', null, 'Mozilla/5.0', 'worker crashed', now() - (g * 300) * interval '1 second'
from generate_series(1, 5000) g;

-- assignment_participations: each student opened each assignment.
insert into assignment_participations (id, user_id, assignment_id, first_accessed_at)
select pg_temp.u('ap' || s || '-' || a), pg_temp.u('stu' || s), pg_temp.u('asg' || a),
       now() - interval '56 days' + a * interval '7 days' - interval '12 days'
from generate_series(1, 300) s, generate_series(1, 12) a;

analyze;
