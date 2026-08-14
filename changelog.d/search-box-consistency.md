### Changed

- **Every list-filter box is one control, in dress as well as in code.** The
  five person/row filters (admin users, enrolled students, assignment
  submissions, instructor activity, admin audit) already shared
  `Public/list-filter.js`, but still came in three widths — two inline
  `--filter-width` values plus a page-local flex basis — and two structures,
  three wrapped in a `.filter-group` and two loose in a toolbar where the label
  could strand from its input on a narrow row. `--filter-width` is now declared
  once in `:root` and may not be re-assigned per page, and every filter sits in
  a `.filter-group`. `Tests/APITests/ListFilterMarkupTests.swift` asserts the
  markup contract by walking the tag structure.
- **A filter now matches a row's data rather than its markup.** Searchable
  columns are the ones the table declares sortable (`th[data-sort-key]`), so the
  Actions column is excluded; a `<select>` contributes its selected option.
  Whitespace-separated terms are ANDed and may match different cells, so
  "lovelace ada" finds Ada Lovelace and no query matches across a cell boundary.
  Matching folds case and diacritics: "Munoz" finds "Muñoz".
- **A filtered list reports itself.** Filtering to nothing shows a per-page
  no-match message (`data-list-filter-empty`), and a `role="status"` region
  announces "Showing 12 of 340" while a filter is active — both silent and
  absent from the page until something is typed. Escape clears the box, which
  Firefox otherwise leaves without a clear affordance.

### Fixed

- **"student" no longer matches every pending row on the students roster.** A
  pending enrolment's Actions cell holds a collapsed registration panel, and
  whole-row text matching searched its field labels — so `student` matched
  through "Student number (optional)" and `email` through "Email (optional)".
  This is the same defect as the pre-S1 `ta` bug, where a role `<select>`'s
  option labels were all row text; both are now covered by one rule.
- **Filtering to no matches no longer leaves a silent empty table.**
  `instructor-students`' own empty-state message counts tbody rows *including*
  the ones the filter hid, so it stayed hidden exactly when it was needed; the
  other two live filters had no such message at all.
- **The activity and audit filters get the same autofill suppression as the
  live ones.** `list-filter.js` scoped its readonly-until-focus suppression to
  inputs carrying `data-list-filter`, leaving the two GET-form filters with a
  bare `autocomplete="off"` — which the component's own comment records as
  insufficient against password managers, and which is why some search boxes
  carried an autocomplete attribute in markup and others did not. The component
  now suppresses on every `.filter-input`; no filter declares `autocomplete` in
  markup.
- **`instructor-activity` renders its page styles inside the document.** Its
  `<style>` block sat after `#endextend`, outside the `content` export, so it
  was emitted past `</html>` and survived only on browser error-recovery.

### Performance

- **Live filtering does 6–9× less work per keystroke** (0.34 ms vs 3.16 ms over
  5,000 rows; 0.022 ms vs 0.133 ms over 200). Folded cell text is cached in a
  `WeakMap` keyed by the `<tr>`, so a poll repaint's new rows invalidate it for
  free; `hidden` is written only when it changes; and a keystroke that narrows
  the query skips the string work for rows already hidden, which cannot match a
  stricter query.
