### Added

- **LTI 1.3 grades through AGS.** A course linked to an LMS can send its grades through the LTI Assignment and Grade Services instead of the Valence sync. An instructor selects it on the new LMS grades page (linked from the LEARN tab); the page also lists failed pushes and has a "Sync now" action. Chickadee creates one line item per assignment and sends each student's best grade, with the same override, best-of and class-goal rules as Valence. A course uses one transport at a time, and Valence stays the default. Design: `docs/lti-1-3.md`.
