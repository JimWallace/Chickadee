### Changed

- **Documented the assignment-language transition.** `docs/language-declaration.md`
  records the rule the multi-language arc landed on — every assignment declares
  its language and nothing infers one — along with the four creation doors that
  enforce it, the single boundary that still derives a declaration before
  recording it, the shapes deleted because the compiler could never see them go
  wrong, and a per-site table of the remaining `?? .python` fallbacks separated
  by whether they sit on an authoring path or a grading one.
