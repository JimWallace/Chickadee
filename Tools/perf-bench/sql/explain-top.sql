-- EXPLAIN (ANALYZE, BUFFERS) of the most expensive statements seen in the
-- per-page and load runs, with real values at the seeded size.
\pset pager off
select string_agg(quote_literal(user_id::text), ',') as stu_ids
  from course_enrollments where role = 'student' \gset
select 'setup-' || md5('setup12') as setup12 \gset
select string_agg(quote_literal(id), ',') as sub5k from (
  select id from submissions where kind = 'student' and id like 'sub-%' order by id limit 5000) x \gset
select string_agg(quote_literal(id), ',') as setup_ids from test_setups \gset

\echo '### Q1 grades CSV / gradeSummariesBySubmissionID: results by 5000 submission ids, sorted'
explain (analyze, buffers)
select id, submission_id, source, earned_points, total_points, pass_count, total_tests, received_at
from results where submission_id in (:sub5k) order by received_at desc;

\echo '### Q2 grades CSV / loadGradesCSVSubmissions: every student submission of the course'
explain (analyze, buffers)
select id, user_id, test_setup_id from submissions
where kind = 'student' and test_setup_id in (:setup_ids) and user_id in (:stu_ids);

\echo '### Q3 instructor submissions / bestGradePercentByStudent'
explain (analyze, buffers)
select s.user_id, max(case when r.total_points > 0 and r.earned_points is not null
                           then r.earned_points / r.total_points * 100 end)
from results r join submissions s on s.id = r.submission_id
where s.test_setup_id = :'setup12' and s.kind = 'student' and s.user_id in (:stu_ids)
group by s.user_id;

\echo '### Q4 instructor submissions / studentsWithGradeSourceDisagreement'
explain (analyze, buffers)
select r.submission_id, s.user_id from results r join submissions s on s.id = r.submission_id
where s.test_setup_id = :'setup12' and s.kind = 'student' and s.user_id in (:stu_ids)
group by r.submission_id, s.user_id
having bool_or(r.source = 'browser') and bool_or(r.source is null or r.source <> 'browser');

\echo '### Q5 instructor submissions / submissionSummaryByStudent'
explain (analyze, buffers)
select user_id, id, total from (
  select user_id, id, row_number() over (partition by user_id order by submitted_at desc, attempt_number desc) rn,
         count(*) over (partition by user_id) total
  from submissions where test_setup_id = :'setup12' and kind = 'student' and user_id in (:stu_ids)) x
where rn = 1;

\echo '### Q6 claim / ClaimCandidateLoader.pending (fresh student, oldest 50)'
explain (analyze, buffers)
select * from submissions where status = 'pending' and kind = 'student' and retested_at is null
order by retested_at asc, submitted_at asc limit 50;

\echo '### Q7 claim / hasPendingWork probe'
explain (analyze, buffers)
select id from submissions where status = 'pending' order by kind asc limit 1;

\echo '### Q8 student submission page / WardrobeUnlockStore.graded (no setup filter)'
explain (analyze, buffers)
select r.earned_points, r.total_points, r.pass_count, r.total_tests, s.test_setup_id, s.attempt_number, s.submitted_at
from results r join submissions s on r.submission_id = s.id
where s.user_id = md5('stu1')::uuid and s.kind = 'student';

\echo '### Q9 admin dashboard / SubmissionRetentionService.submissionCountsByCourse'
explain (analyze, buffers)
select test_setup_id, count(*) as total from submissions where test_setup_id in (:setup_ids) group by test_setup_id;

\echo '### Q9b instructor list / submitters per assignment'
explain (analyze, buffers)
select test_setup_id, count(distinct user_id) from submissions
where test_setup_id in (:setup_ids) and kind = 'student' and user_id in (:stu_ids) group by test_setup_id;

\echo '### Q9c admin dashboard / UserActivityChartService window'
explain (analyze, buffers)
select user_id, created_at from user_activity_events where created_at >= now() - interval '1 day' and created_at <= now();

\echo '### Q10 request_metrics FK check on submission delete (what each DELETE runs)'
explain (analyze, buffers)
select 1 from request_metrics where submission_id = 'sub-x' for key share;
