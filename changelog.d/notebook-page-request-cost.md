### Changed

- **The notebook page stops repeating its per-request queries.** The
  (user, course) role lookup — asked four times per notebook page load by
  the enrollment guard, the staff check, the effectively-open check, and the
  closed-assignment gate — is now memoized on the request, the same
  per-request caching `resolveActiveCourse` already had; the submit form and
  the submission gate share it (#1382 item 3). Per-student dataset files are
  no longer re-sliced and rewritten on every visit: an unchanged seed, spec,
  and source with all files present skips the work, while a re-seed, a spec
  edit, a re-uploaded source, or a deleted file still re-materializes.
