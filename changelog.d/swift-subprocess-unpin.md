### Changed

- **swift-subprocess is back on the upstream release (1.0.2).** Since 1.0.1
  its Linux child comes from `posix_spawn` rather than a raw `clone3` for
  every configuration Chickadee uses, which removes the glibc 2.41 launch
  hang; the temporary fork is no longer used.
