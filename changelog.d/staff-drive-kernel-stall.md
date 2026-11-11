### Fixed

- **The authoring editor's kernel boots again in Safari for course staff who are not admins.** On the server drive the kernel's file system reads the `users` folder on its way to a staff draft, and the server refused that listing to everyone but admins. Safari's file transport never answered the kernel after the refusal, so the kernel stayed in "starting" until the stall notice. Non-admin staff now read `users` as a student does: one child, their own folder.
- **An editor error that is not an `Error` object is reported by its fields.** The kernel diagnostics recorded such a rejection as "[object Object]"; they now record its type and a few fields, with the user's folder id removed.
