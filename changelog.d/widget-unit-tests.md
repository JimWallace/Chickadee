### Added

- **`inplace-forms.js` has unit tests.** It is what actually submits an
  author's work from the workbench, and it had none: the render tests never run
  page JS, and the visual harness does not capture the workbench. The suite
  pins the rule the file exists for — each form keeps its OWN encoding, because
  the section and secret-reveal endpoints decode urlencoded bodies and moving
  them to multipart would change how their handlers parse — plus the CSRF
  header on both encodings, the disabled submit button, and the failure path:
  a failed save must resolve false, show its inline banner, and NOT re-render
  the pane as though it had worked.
