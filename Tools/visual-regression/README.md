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

One representative per page-anatomy family (see "Page archetypes" in
`docs/ui-design.md`): `login`, `student-dashboard`, `student-submit`,
`submission-pending`, `submission-graded`, `student-account`, `error-404`,
`instructor-assignments`, `instructor-students`, `instructor-slip-days`,
`admin-dashboard`, `admin-users`, `admin-alerts`, `admin-course-new` — each
as `--light` and `--dark`. Page names are the baseline filenames; the list
lives in `pages.mjs`, shared by the capture and the a11y scan so the two
cannot drift. (`admin-audit` is deliberately excluded: its rows are
per-run UUIDs and timestamps.)

A page captured with **no committed baseline** bootstraps per page: the run
passes with a loud warning and the capture is uploaded in the
`visual-baselines-bootstrap` artifact — commit it to `baselines/` in the
same PR to flip the page to enforcing. Baselines are CI-canonical, so this
artifact round-trip is the normal way to add a page.

## The graded result page

`submission-graded` is the only page whose fixture state the seed has to
manufacture. The harness attaches no runner on purpose — that is what keeps
`submission-pending` deterministically pending — so a worker-graded submission
never produces outcomes. The seed instead posts a fixed `TestOutcomeCollection`
to `POST /api/v1/submissions/browser-result`, the same session-authed endpoint
the in-browser grader uses, which needs no runner and no HMAC secret.

Every value in that collection is a constant. It reaches a pixel baseline, so
nothing in it may derive from the clock, the run or the machine — including its
`timestamp`, which is pinned rather than `new Date()`.

One value is not the seed's to pin: the stored artifact for a browser-graded
submission is named from the generated submission id, so the download button
reads `Download sub_<uuid>.ipynb`. `capture.mjs` rewrites that text, matching
the link by href and replacing it only when it carries a generated id — an
uploaded artifact keeps the student's own filename, which is already
deterministic, and rewriting it too would restage the pending page's baseline
for nothing.

The fixture suite is weighted and spans three tiers on purpose: points labels
render only on a weighted assignment, and the masked hidden-test block only
when secret tests exist. A single unweighted public test draws neither.

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

## Running in a Claude remote container

The remote-execution image pre-installs Playwright browsers at
`/opt/pw-browsers` (with `PLAYWRIGHT_BROWSERS_PATH` pointing there and
downloads disabled), but the browser build there tracks the image, not this
package's lockfile — so a newer `playwright` from `npm ci` will look for a
`chromium_headless_shell-<rev>` directory the image does not have and fail
with "Executable doesn't exist". Do not run `npx playwright install`
(downloads are disabled by policy). Bridge the layout instead — symlink the
expected revision directory to the installed binary:

```
ls /opt/pw-browsers
mkdir -p /opt/pw-browsers/chromium_headless_shell-REV/chrome-headless-shell-linux64
ln -sf /opt/pw-browsers/chromium_headless_shell-OLDREV/chrome-linux/headless_shell /opt/pw-browsers/chromium_headless_shell-REV/chrome-headless-shell-linux64/chrome-headless-shell
```

with REV taken from the error message and OLDREV from the `ls`. The compare
then runs against a slightly different Chromium than CI captured the
baselines on; the anti-aliasing budget absorbs it in practice, but treat a
borderline diff on text-heavy pages as suspect and let the CI `visual` job
arbitrate.
