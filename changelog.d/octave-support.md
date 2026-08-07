### Added

- **Octave is a full assignment language.** `AssignmentLanguage` is now
  `.python | .r | .lua | .octave`: `.m` test scripts grade on the native
  worker (`octave-cli`, now on the runner and CI images together with the
  gnuplot-nox + freefont pair that makes headless figures work) and in the
  browser via the vendored `xeus-octave` kernel (`chickadee-octave`, xeus
  6.0.5, ~12 s cold boot, no per-statement cost). All eight pattern-family
  kinds render and execute; notebook checks cover seven of ten — more than
  Lua, because both of Lua's opposite answers were re-measured for Octave:
  `figureCount` is supported (plotting is core Octave, verified in both
  runners) and `cellContains` keeps `regex: true` (Octave's regexp is PCRE).
  The four data-frame kinds and `astStructure` are refused at save time with
  a message naming what is supported. Personalization evaluates `=`
  expressions through an `octave-cli` driver sharing the same Horner seed
  fold as R and Lua, so a student's seed is one number in every language.
  Generated literals render mixed-type arrays as cell arrays — never `[...]`,
  whose silent char coercion (`[65, "bc"]` is `"Abc"`) is Octave's most
  dangerous default — and equality is `isequaln`-based, so authored nulls
  (`NA`) match missing values and 1 == 1.0 == true, matching what students
  can observe with Octave's own operators.
