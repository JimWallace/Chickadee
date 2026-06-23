### Changed

- **LEARN grade sync now matches students by username, not just student
  number.** Grade pushes resolve a Chickadee student against the course LEARN
  **classlist** by **username first** (the WatIAM id — present for both SSO and
  local logins and equal to the LEARN username at UW), then fall back to the
  student number (`OrgDefinedId`) and the legacy `users/?orgDefinedId=` lookup.
  The classlist decode now keeps D2L's internal `Identifier`, so SSO students who
  carry no student-number claim sync **without any manual data entry**. No schema
  change — the resolved D2L user id still caches on the existing
  `brightspace_user_id` field and is reused thereafter. Resolution does one
  classlist read per course per sweep, which also sidesteps the org-level user
  lookup a course-scoped API role may not be permitted to call.
