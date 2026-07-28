### Changed

- **One authoring-voice guide per course, inherited from the Chickadee
  default.** The instructor MCP tab no longer shows a fixed house guide plus a
  separate "additional guidance" box. It now shows a single editable guide,
  seeded with Chickadee's default authoring voice: a course starts on the
  default, and an instructor edits that text into the course's own. A
  customized guide *replaces* the default for content authored in that course
  (it is appended as a labelled block at `initialize`, where an inheriting
  course adds nothing, since the default is already there), and
  `chickadee://course/<code>/authoring-guidance` now resolves for every
  authorable course, serving whichever guide is in force. Resetting, emptying
  the box, or saving text that still matches the default verbatim returns the
  course to inheriting, so later changes to the default keep flowing through.
