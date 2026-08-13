### Fixed

- **Lua and Octave kernel boots now take the editor asset fast path.** The
  fast path's allowlist was a hand-written list naming Python and R, so a Lua
  (19 MB) or Octave (142 MB, the largest env shipped) kernel boot sent every one
  of its ~50 package tarballs through the full middleware chain — session
  lookup, user lookup, activity middleware — that the fast path exists to skip.
  It failed open, so nothing broke and no test noticed; the boot was just
  needlessly expensive. The prefixes are now derived from
  `AssignmentLanguage.allCases`, so a seventh language needs no edit here, and a
  new test reads the vendored tree on disk and fails if any shipped kernel is
  missing from the list.
