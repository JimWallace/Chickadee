### Changed

- **Login is a card, and the student dashboard sorts, filters and survives a
  phone.** The auth panel gains a surface, border and padding; the mascot drops
  from 200px to 72px so it stops competing with the sign-in controls for the
  first screenful. The assignment table's Name / Status / Due / Grade headers
  become sortable, each section gains a filter box, and the Due column renders a
  relative countdown (with the absolute date beneath it and as the no-JS
  fallback) per the house timestamp rule. At phone width, where `.col-hide-phone`
  drops the Due and History columns, the name cell restates both through the new
  `.assignment-phone-meta`. The slip-day line becomes a chip phrase rather than a
  sentence, the empty state explains itself, and a row with nothing to do renders
  a dash instead of an empty cell.
