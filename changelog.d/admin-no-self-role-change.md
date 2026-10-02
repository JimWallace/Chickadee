### Fixed

- **An admin can no longer change their own role.** A self-demotion could leave
  no admin able to undo it. The server now refuses the request with 403, and the
  role menu on the signed-in admin's own row in the Users list is disabled.
- **Changing a role now returns to the Users list.** It used to open the admin
  dashboard, so the saved role was not visible.
