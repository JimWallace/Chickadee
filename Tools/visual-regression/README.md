# Visual regression harness (#1136)

Boots a real `chickadee-server` on an ephemeral SQLite DB, seeds a course +
assignment + student + pending submission over the real HTTP API, screenshots
the key pages in **both** colour schemes with Chromium, and diffs the PNGs
against the committed baselines in `baselines/`.

This closes the gap the static guards leave open: `check-styles.sh` /
`check-design-tokens.sh` prove every value routes through the token system,
and the render tests prove pages render — neither proves a page *looks*
right. The dark-mode banner bugs fixed in #1133 were invisible to every
other check; a baseline diff catches that class on the introducing PR.

## Pages × schemes

`login`, `student-dashboard`, `student-submit`, `submission-pending`,
`instructor-assignments`, `admin-dashboard` — each as `--light` and `--dark`.
Page names are the baseline filenames; add pages in `capture.mjs`.

## Running locally

```bash
swift build --product chickadee-server
cd Tools/visual-regression
npm ci
./run-visual.sh
```

Exit 1 on drift, with `*.diff.png` / `*.actual.png` evidence. In CI
(`visual-regression.yml`, path-filtered, not a required check) the evidence
uploads as the `visual-diffs` artifact.

## Intentional UI change?

```bash
./run-visual.sh --update
```

then review and commit the changed baselines **in the same PR** — the
baseline image diff becomes part of code review. If no baselines are
committed at all, the harness runs in bootstrap mode: captures are saved
(uploaded in CI as `visual-baselines-bootstrap`) and the run passes.

## Accessibility scan (#1137)

`./run-a11y.sh` runs axe-core over the same seeded pages in both schemes
(`a11y.mjs`; the CI job runs it after the visual compare).  Critical and
serious violations always fail; moderate/minor are a shrink-only count
ratchet against `a11y-baseline.json` (growth fails, shrinkage prints the
lower-the-baseline note).  With no baseline committed it bootstraps the
same way the visual harness does.

## Determinism

Fixed 1280×900 viewport, `deviceScaleFactor: 1`, `en-CA` /
`America/Toronto`, fonts pinned to DejaVu, animations/transitions/carets
disabled, and dynamic regions masked (`.js-relative-time`,
`.admin-version-banner`, `canvas`). Comparison is anti-aliasing-aware
(`pixelmatch`, threshold .15) with a 0.1 % differing-pixel budget — sub-pixel
font drift passes, palette/layout changes fail.

**Sensitivity floor:** the 0.1 % budget (~1,150 px at 1280×900) is sized to
absorb cross-runner anti-aliasing drift (~500 px observed on the busiest
page). Component-scale changes (banners, cards, backgrounds) far exceed it;
a recolour confined to a few words of small text can fit under it — the
dark-mode chip-contrast fix on the dashboards moved only ~356 px and
passed. That class is exactly what the axe-core scan catches (contrast is
checked computationally, not by pixels), which is why the two checks run
together. Baselines are
**CI-canonical**: regenerate them in the CI image (or trust the bootstrap
artifact) rather than committing captures from a host with different font
rendering.
