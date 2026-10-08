### Changed

- **pixelmatch 8 in the visual-regression harness.** pixelmatch 8 measures colour difference as an OKLab HyAB distance instead of YIQ. Measured on the committed baselines, the existing threshold of 0.15 keeps the same tolerance for rendering noise and catches smaller palette changes than before, so the threshold stays as it is.
