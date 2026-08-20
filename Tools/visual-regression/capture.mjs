// capture.mjs — seed a running chickadee-server over its real HTTP API, then
// screenshot the key pages in BOTH colour schemes (#1136).
//
//   node capture.mjs <baseURL> <outDir>
//
// The seed flow is adapted from Tools/editor-smoke-test/notebook-page-check.mjs:
// register an instructor (first user becomes admin, and course creation seeds a
// per-course instructor enrollment), create an auto-enroll course, upload a
// worker-graded test setup, then register + log in a student (auto-enrolled on
// login) and submit once so the pending-results page renders.
//
// Determinism measures (the whole game — see docs/ui-design.md):
//   * fixed viewport / deviceScaleFactor / locale / timezone;
//   * fonts pinned to DejaVu (present in the CI image and dev containers) so
//     system-ui doesn't pick a host-specific face;
//   * animations, transitions, and carets disabled;
//   * dynamic regions (relative timestamps, version banner, canvas charts)
//     masked with a solid box via Playwright's screenshot mask.
import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";
import { seed } from "./seed.mjs";
import { pageList } from "./pages.mjs";

const baseURL = process.argv[2];
const outDir = process.argv[3];
if (!baseURL || !outDir) {
  console.error("usage: node capture.mjs <baseURL> <outDir>");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

// Selectors hidden from every screenshot: content that legitimately differs
// run-to-run.  Keep this list SHORT — every mask is a blind spot.
const MASKS = [
  ".js-relative-time",     // "3 minutes ago" timestamps (relative-time.js)
  ".admin-version-banner", // vX.Y.Z on the admin page
  ".worker-secret-input",  // auto-generated diceware secret — new every boot
  "canvas",                // sparkline charts draw async
];


// ---------------------------------------------------------------------------
async function main() {
  console.log(`Seeding fixture data via ${baseURL} …`);
  const { setupID, instructorState, studentState, resultsPath, gradedResultsPath } =
    await seed(baseURL);
  console.log(`Seeded setup ${setupID}; results page: ${resultsPath || "(none)"}`);

  // Page list is shared with the a11y scan — see pages.mjs.
  const PAGES = pageList({
    setupID, instructorState, studentState, resultsPath, gradedResultsPath,
  });

  const browser = await chromium.launch();
  let failures = 0;
  for (const scheme of ["light", "dark"]) {
    for (const p of PAGES) {
      const context = await browser.newContext({
        baseURL,
        colorScheme: scheme,
        viewport: { width: 1280, height: 900 },
        deviceScaleFactor: 1,
        reducedMotion: "reduce",
        locale: "en-CA",
        timezoneId: "America/Toronto",
        storageState: p.state || undefined,
      });
      const page = await context.newPage();
      try {
        await page.goto(p.path, { waitUntil: "networkidle", timeout: 30_000 });
        await page.addStyleTag({
          content: `
            *, *::before, *::after {
              animation: none !important;
              transition: none !important;
              caret-color: transparent !important;
              font-family: 'DejaVu Sans', sans-serif !important;
            }
            code, pre, kbd, samp, .mono, [class*="mono"] {
              font-family: 'DejaVu Sans Mono', monospace !important;
            }
          `,
        });
        // Freeze the width of every masked relative-time cell.
        //
        // A mask box is sized to the element it covers, and these elements are
        // sized by their text — which is a live phrase ("now", "1 minute ago",
        // "2 minutes ago") derived from a session created seconds earlier. So
        // the SAME page could produce different mask widths between two runs,
        // or even between the light and dark passes of one run, and the diff
        // read as a real change. That is exactly what it did: a roster page
        // came back 0.3% different in CI and identical locally, in light only.
        // Replacing the text with a constant makes the box a constant.
        //
        // `.submission-history-latest` is the same problem from a different
        // source: it renders the submission's absolute timestamp, which is
        // "now" at seed time, so it moves every run. It carries no
        // js-relative-time class (it is server-rendered, not JS-formatted),
        // so it needs naming here explicitly. It only became visible when the
        // fixture started publishing an OPEN assignment — before that the
        // student dashboard had no rows at all.
        //
        // The submission download link is a third instance of the same problem
        // from a third source: the stored artifact for a browser-graded
        // submission is named from the generated submission id, so the button
        // reads "Download sub_b92d0d05.ipynb" — a fresh UUID every run. It
        // carries no class of its own, so it is matched by its href.
        await page.evaluate(() => {
          document
            .querySelectorAll(".js-relative-time, .submission-history-latest")
            .forEach((el) => {
              el.textContent = "0000-00-00 00:00";
            });
          // Only the GENERATED name is replaced. An uploaded artifact keeps
          // the student's own filename ("solution.py"), which is already
          // deterministic — rewriting it too would restage the pending page's
          // baseline for no gain, and that diff lands at 98% of the tolerance
          // budget, i.e. it would pass while being wrong.
          document
            .querySelectorAll('a[href^="/api/v1/submissions/"][href$="/download"]')
            .forEach((el) => {
              if (/sub_[0-9a-f]{6,}/i.test(el.textContent || "")) {
                el.textContent = "Download submission";
              }
            });
        });
        await page.waitForTimeout(300); // let post-load JS (tables, badges) settle
        const file = path.join(outDir, `${p.name}--${scheme}.png`);
        await page.screenshot({
          path: file,
          fullPage: true,
          animations: "disabled",
          mask: MASKS.map((sel) => page.locator(sel)),
          maskColor: "#FF00FF",
        });
        console.log(`captured ${p.name}--${scheme}`);
      } catch (err) {
        failures++;
        console.error(`FAILED to capture ${p.name}--${scheme}: ${err.message}`);
      } finally {
        await context.close();
      }
    }
  }
  await browser.close();
  if (failures > 0) {
    console.error(`${failures} page(s) failed to capture`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
