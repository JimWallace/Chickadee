### Changed

- **The classmate chooser reads five columns, not whole submissions.** `latestStudentSubmissionsByUser` picks each student's newest complete submission and its id, owner, time, filename and path in one SQL statement, as a `LatestStudentSubmission`, instead of loading every picked row as a full model with its materialization blob. It runs on the claim path of every class activity job.
