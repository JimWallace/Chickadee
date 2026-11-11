### Changed

- **The staff-draft browser probe runs as a course instructor who is not an admin.** `authoring-draft-check.mjs` signed in as the first account, which is always an admin, so CI never met the `users` listing that the server drive refused to other staff and that left the Safari kernel at "starting". A throwaway admin now creates the course and adds a second, non-admin account as its instructor, and the probe fails unless the editor's kernel reaches idle within `SMOKE_KERNEL_MS`. Its saves press Ctrl+S or Cmd+S by platform, so the probe also passes on a Mac.
