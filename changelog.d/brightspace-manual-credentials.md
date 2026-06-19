### Added

- **BrightSpace "Set credentials manually" (admin).** A new field on the Admin →
  BrightSpace page accepts a pasted Valence **User ID + User Key** — for
  institutions (like UW) that register a *central credential service* as the
  app's Trusted URL (`d2l-api-cred.fast.uwaterloo.ca`) rather than this server's
  own callback, so the in-app authorize handshake can't run. The pair is
  `whoami`-verified against D2L, stored (same `brightspace_credentials` row,
  taking precedence over env), and the live client is rebuilt — connecting grade
  sync with no env edit or restart. See `docs/brightspace-setup.md` Step 1C.
