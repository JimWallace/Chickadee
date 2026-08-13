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
  const { setupID, instructorState, studentState, resultsPath } = await seed(baseURL);
  console.log(`Seeded setup ${setupID}; results page: ${resultsPath || "(none)"}`);

  // Page list is shared with the a11y scan — see pages.mjs.
  const PAGES = pageList({ setupID, instructorState, studentState, resultsPath });

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
            /* Relative timestamps are masked, but the mask cannot hide their
               LAYOUT: the phrase's width ("just now" vs "2 minutes ago")
               varies run-to-run and drives auto table-column widths, which
               shifted every column of the students table by a few px and
               failed the diff while the dark capture of the same DOM passed.
               Pin the box so the phrase cannot move the layout. */
            .js-relative-time {
              display: inline-block !important;
              width: 9ch !important;
              overflow: hidden !important;
              white-space: nowrap !important;
            }
          `,
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
