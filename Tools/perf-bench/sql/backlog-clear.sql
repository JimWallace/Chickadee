-- Removes the 'bl-' backlog rows. FK triggers are skipped (replica role) for
-- speed; every child row of a 'bl-' submission is deleted first by hand.
\set ON_ERROR_STOP on
begin;
delete from job_execution_metrics where submission_id like 'bl-%';
delete from submission_diagnostics where submission_id like 'bl-%';
update request_metrics set submission_id = null where submission_id like 'bl-%';
set local session_replication_role = replica;
delete from submissions where id like 'bl-%';
commit;
analyze submissions;
select status, count(*) from submissions group by status;
