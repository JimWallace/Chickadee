### Added

- **The two `LanguageDescriptor` fields that state facts about a real
  interpreter are now measured against one.** Most of the descriptor is
  normative — it decides something and the code obeys — but
  `interpreterProbe` and `workingDirectoryIsOnDefaultSearchPath` are claims
  about the outside world, true or false independently of what the descriptor
  says, and nothing checked them. Both have already been wrong in ways that
  produced no error: `--version` on lua exits 1, so no runner ever advertised
  Lua and an assignment requiring it queued forever; and the Octave search-path
  answer was, in the field's own words, "an armchair answer".

  The probe test reproduces the Lua failure exactly when the arguments are
  reverted. The search-path test measures the observable consequence rather than
  parsing a path listing: a module in one directory, the script that loads it by
  name in another, run with the working directory set to the module's and the
  search-path variable removed.

  That two-directory separation is the whole measurement. Collapsing it
  disagreed with a *correct* descriptor twice while the test was being written —
  put the module beside the script and every language looks alike, because a
  language that puts the script's directory on its path finds it too, which is a
  different fact. Python is the case that distinguishes them. Neither descriptor
  value was changed; both disagreements were the test's fault, which is worth
  recording because the tempting move on a red measurement is to trust the
  measurement.

### Changed

- **"Write a custom script" now names what it is competing with.** Eight of the
  nine Python script templates were retired because they duplicated a
  pattern-family kind in a worse form, and the ninth is now a kind too — which
  left the custom-script option looking like the ordinary way to write a test.
  Selecting it lists the first-class types available on this assignment,
  derived from the catalog's own family entries rather than from a second list,
  so a tenth kind appears there the day it is added.

  This closes the last open item in `docs/authoring-parity.md`: every retired
  template now has a named equivalent, `differential` included.
