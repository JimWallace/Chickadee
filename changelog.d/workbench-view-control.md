### Changed

- **The notebook view control is now always shown, and disabled when it does not
  apply.** It used to be omitted entirely for a notebook carrying no
  `{{placeholders}}`, which is indistinguishable from the control failing to
  draw. It is now rendered unavailable, with the reason in its tooltip: this
  notebook has no per-student placeholders, so there is only one version of it.
