### Fixed

- **Deleting an assignment no longer fails with "Session refreshed".** The
  three assignment delete forms in the Ungrouped table on the instructor
  dashboard (the `closed` / `open` / preview branches in `assignments.leaf`)
  were missing `#csrfFormField()`, so `POST /instructor/:id/delete` arrived
  without a `_csrf` token and the CSRF middleware rejected it with a 403.
  Because every assignment renders in that Ungrouped table when no course
  sections are defined, every delete failed; moving an assignment into a
  section (whose table already emitted the token) was the only workaround.
  All eight delete forms on the page now emit the hidden CSRF field.
