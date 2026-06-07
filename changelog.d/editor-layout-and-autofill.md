### Fixed

- **Audit-log "Actor" filter no longer offers credential autofill.** The field
  is now `autocomplete="off"` like the other admin filter inputs. A site-wide
  default was also added (`app.js`): forms that don't opt into autocomplete and
  carry no password field now default to `autocomplete="off"`, so stray
  username/password autofill prompts stop appearing on non-credential forms
  across the app. Login/register/admin-secret forms opt their fields in
  explicitly and are unaffected.

### Changed

- **Assignment editor: "Add Support File" and "Add Input" moved above their
  tables.** Both now sit in a header bar beside a heading ("Files" /
  "Global Inputs"), mirroring the Test Suite section header, instead of being a
  trailing table row — which also frees two rows from the table area. The
  Global Inputs table drops its redundant "Global input" label column so the
  value field gets that horizontal space.
