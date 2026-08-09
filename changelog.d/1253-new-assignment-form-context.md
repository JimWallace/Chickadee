### Changed

- **The new-assignment page's bounce-back redirect has one builder instead of
  two.** The five form fields that survive a redirect to `/instructor/new`
  (title, due date, start date, section, draft id) are now a
  `NewAssignmentFormContext`, and the two functions that each assembled the
  same query string from them — in a different field order — collapsed into one
  method on it. Two `function_parameter_count` lint exemptions went with them.
  No behavioural change: a correct consumer reads query parameters by name, and
  the emitted fields and values are unchanged.
