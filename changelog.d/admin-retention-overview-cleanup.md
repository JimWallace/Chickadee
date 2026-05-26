### Changed

- **Admin Retention tab reworked around Restore + Delete.** Archived courses now live only on the Retention tab (they no longer appear on the Overview). Each row has icon actions to Restore (unarchive) and Export a course bundle at any time, plus a permanent Delete once the course is past its retention window. The table is sortable by column.
- **Overview courses table shows a Submissions count** in place of the always-"active" Status column.

### Removed

- **Submission "Purge" action**, folded into the retention lifecycle (restore any time; permanently delete course + data once the retention window elapses).
- **"Auto-start local" runner checkbox** from the admin Overview (the worker-secret control is unchanged).
- **Redundant page-title headers** on the admin Storage and Users tabs.
