### Added

- **MCP can now author a C++ assignment.** Two new content tools close the gap
  the C++ language arc left behind: `set_submission_mode` (`notebook` /
  `uploadOnly`, the MCP twin of the edit page's control) and
  `set_assignment_language` (declare `python` / `r` / `lua` / `octave` / `cpp`).
  C++ was previously unreachable through MCP entirely — its language is the one
  that cannot be derived, since it has no editor kernel for a notebook
  kernelspec to name and its generated tests are deliberately extension-free
  `.sh` wrappers — so a C++ assignment could only be created by uploading a
  hand-written `test.properties.json`. The catalog is now 54 tools.

  Both halves of the `cpp ⟺ uploadOnly` invariant are enforced, each from its
  own side: declaring C++ on a notebook-mode assignment is refused, and a C++
  assignment cannot be flipped back to the notebook workflow it has no kernel
  for. A language change is refused once generated tests exist, since every
  generated filename carries the current language's extension — declare the
  language before authoring families, which is the natural order anyway.
