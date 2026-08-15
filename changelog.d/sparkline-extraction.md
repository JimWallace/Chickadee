### Changed

- **The sparkline renderer moved out of `chickadee-ui.js` into
  `Public/sparkline.js`** (`ChickadeeSparkline.render`). That module is loaded
  from `base.leaf` on every page, and it had accumulated eighteen unrelated
  functions behind one name — escaping, CSRF, a fetch wrapper, a status line, a
  modal, a chart renderer, an accordion, two surface swappers. Drawing a chart
  is not a shared utility in the sense that escaping a string is, and its two
  callers are both dashboards, so every other page was carrying markup-building
  code it never called.

  No behaviour change: the two call sites (the admin dashboard's diagnostic
  cards and the assignment cards) point at the new name directly rather than
  through a forwarding shim, which is the point — a shim would leave the module
  being shrunk still naming what left it. It also picks up its first tests, nine
  of them, including the one that matters most to read: "no data" and "zero"
  must not draw alike.
