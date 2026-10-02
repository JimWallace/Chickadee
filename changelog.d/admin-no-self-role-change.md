### Fixed

- **An admin can no longer change their own role.** A self-demotion could leave
  no admin able to undo it. The server now refuses the request with 403. The
  Users list shows the role of the signed-in admin as text, with no menu.
