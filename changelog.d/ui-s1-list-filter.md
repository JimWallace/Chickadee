### Changed

- **One list-filter control (audit S1).** Every list filter now wears the
  same dress — a visible "Filter" label beside a search input — and the
  three hand-rolled inline filter scripts (admin users, enrolled students,
  assignment submissions) are replaced by one shared, unit-tested
  implementation (`Public/list-filter.js`). The shared matcher reads a role
  dropdown's selected value rather than its option labels, so typing "ta"
  no longer matches every row on the pages that matched raw row text. The
  activity and audit-log filters keep their server-side Filter/Clear form
  but now share the same look. A new style guard keeps the replaced idioms
  from returning.
