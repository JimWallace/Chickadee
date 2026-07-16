### Added

- **Personal-data export (#557).** Any signed-in user can request a copy of
  the personal information Chickadee holds about them — profile, course
  enrollments, submissions (including the uploaded files), grading results,
  grading adjustments, and audit-log activity — from the account page,
  delivered as a single zip with a README manifest (FIPPA / PIPEDA subject
  access). Generation runs asynchronously; results are tier-filtered to
  exactly what the user can already see; requests are limited to one per day
  per user; both the request and the download are audit-logged; generated
  archives are deleted after three days.
