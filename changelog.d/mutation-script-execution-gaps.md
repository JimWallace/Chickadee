### Fixed

- **Closed four mutation survivors on the runner's descriptor hygiene.** Every
  captured pipe end is now asserted to be created close-on-exec, and the
  failed-launch path is asserted to release both read ends. Both defend the
  wedge class behind issues #1233 and #1139: a pipe end that survives an exec is
  inherited by an unrelated child, which postpones EOF on the runner's read and
  parks a pool thread until that unrelated process exits.
