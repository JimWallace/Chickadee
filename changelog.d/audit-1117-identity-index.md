### Fixed

- **One BrightSpace classlist identity index (#1117).** Grade push, section
  sync, and the roster reconciler each reduced the LEARN classlist their own
  way, and the normalization had already drifted: section sync lowercased but
  didn't trim, so a classlist username with stray whitespace matched for
  grade push but silently failed section sync. The new
  `BrightSpaceIdentityIndex` is the single reduction (one trim+lowercase
  normalization, one username-first/student-number-second precedence) consumed
  by all three sweeps and the reconciler. Also folded in: the manual
  "Sync now"/"Push all" re-queue triple-write is one `requeueForImmediateSync`
  helper; the sweep takes `bypassDebounce:` instead of callers fabricating a
  future timestamp; the manual sweep logs failures instead of swallowing them;
  and the Valence client's four copy-pasted response-body reads are one
  `ClientResponse.bodyString(max:)`.
