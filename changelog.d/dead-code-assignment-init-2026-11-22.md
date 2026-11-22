### Removed

- **The `isOpen` convenience initializer of `APIAssignment`.** Only tests called it. The tests now give `visibility:` to the remaining initializer (`.open` for `true`, `.closed` for `false`). Refs #3234.
