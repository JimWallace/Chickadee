### Fixed

- **The create page no longer reports adding starter tests it did not write.**
  "Generate Starter Tests" filtered its work list to empty on any non-Python
  assignment and then reported `N test file(s) added to suite.` from the count
  of files nobody wrote. It now says the templates are Python-only and names the
  assignment's language. Its solution scan also passes the declared language to
  `/instructor/scan-notebook`, as the family editor's scan already did — without
  it, a declared-R assignment whose solution still carried a Python kernelspec
  scanned as Python and listed functions no generated test could be written for.
  The whole panel moved out of `assignment-new.leaf` into
  `Public/generated-starter-tests.js`, where it is linted and testable; both
  defects were invisible from the template.

- **Copy that named C++ as the only upload-only language now names every
  upload-only language.** Racket has been the second since it shipped, and the
  enforcement predicate (`requiresUploadOnlySubmission`) picked it up
  immediately because it asks `editorSupport` — so the rule covered Racket while
  the explanation did not, in both authoring pages and four MCP tool
  descriptions. All six sites now interpolate `LanguageProse`, which derives
  predicate-defined language lists the way `MCPLanguageProse` derives the full
  one. `MCPLanguageCoverageTests` gained the matching guard: any served sentence
  about upload-only that names one upload-only language must name all of them.
  Its existing guard could not see this class, because it ignores
  single-language mentions on purpose.

- **The pattern-family variables table no longer calls every value a Python
  literal.** The `Value (JSON / Python literal)` column header was shown to R,
  Lua, Octave, C++ and Racket authors — the same defect as the adjacent "Python
  default" placeholder fixed earlier, missed because this instance lived in Leaf
  rather than in the editor's JavaScript. It now names the assignment's own
  language. The required-Languages placeholder on the create page and the
  student-facing "the Python kernel" prose on the editor-reset and notebook
  pages were stale the same way; the placeholder is now derived from
  `AssignmentLanguage.allCases`, and the kernel prose no longer names a language.
