-- Makes :n fresh student submissions (ids 'bl-...') pending, spread over the
-- 12 assignments and 300 students, oldest first. Re-runnable: existing
-- 'bl-' rows are reset to pending rather than deleted, because deleting a
-- submission seq-scans request_metrics (slow before the request_metrics.submission_id index).
\set ON_ERROR_STOP on
delete from job_execution_metrics where submission_id like 'bl-%';
delete from submission_diagnostics where submission_id like 'bl-%';
update submissions set status = 'pending', worker_id = null, assigned_at = null
 where id like 'bl-%' and status <> 'pending';
insert into submissions (id, test_setup_id, kind, status, zip_path, attempt_number, filename, user_id, submitted_at, source_kind)
select 'bl-' || md5('bl' || g), t.id, 'student', 'pending', '/tmp/chickadee-perf/bl.zip', 6, 'assignment.ipynb',
       md5('stu' || (1 + g % 300))::uuid, now() - interval '30 minutes' + g * interval '50 ms', 'upload'
from generate_series(1, :n) g
join (select id, row_number() over (order by id) - 1 as rn from test_setups) t on t.rn = g % 12
on conflict (id) do nothing;
analyze submissions;
select status, count(*) from submissions group by status;
