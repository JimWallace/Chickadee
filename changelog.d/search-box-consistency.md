### Changed

- **Every list-filter box is one control, in dress as well as in code.** The
  five person/row filters (admin users, enrolled students, assignment
  submissions, instructor activity, admin audit) already shared
  `Public/list-filter.js`, but still came in three widths — two inline
  `--filter-width` values plus a page-local flex basis — and two structures,
  three wrapped in a `.filter-group` and two loose in a toolbar where the label
  could strand from its input on a narrow row. `--filter-width` is now declared
  once in `:root`, every filter sits in a `.filter-group`, and
  `scripts/check-styles.sh` fails on a per-page width or a group-less filter.

### Fixed

- **The activity and audit filters get the same autofill suppression as the
  live ones.** `list-filter.js` scoped its readonly-until-focus suppression to
  inputs carrying `data-list-filter`, so the two GET-form filters were left
  with a bare `autocomplete="off"` — which the component's own comment records
  as insufficient against password managers, and which is why some search
  boxes carried an autocomplete attribute in markup and others did not. The
  component now suppresses on every `.filter-input` and binds live filtering
  only where a target table is named; no filter carries `autocomplete` in
  markup.
- **`instructor-activity` renders its page styles inside the document.** Its
  `<style>` block sat after `#endextend`, outside the `content` export, so it
  was emitted past `</html>` and survived only on browser error-recovery. It
  now sits inside the export like every other page's.
