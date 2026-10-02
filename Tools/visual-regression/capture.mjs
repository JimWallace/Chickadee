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
import { pageList, PHONE_PAGE_NAMES } from "./pages.mjs";

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
  "canvas",                // sparkline charts draw async
  // A student's chickadee is DRAWN AT RANDOM and stored, so a fresh fixture
  // run produces a different bird every time — the same category as the
  // diceware secret above. A pixel baseline of it could never be stable, and
  // would not be meaningful if it were: what matters is that the layers stack,
  // the palette resolves and no interpolation leaks, which AccountRoutesTests
  // and AvatarSpecTests assert against the markup instead. Its box is a fixed
  // 3rem, so unlike the text below it needs no width freezing.
  ".avatar",
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

  // The phone check: no page may scroll sideways at 320px (the narrowest
  // phone in use). Not a screenshot — a layout assertion — so it covers every
  // page in the list, not only the ones with a phone baseline.
  for (const p of PAGES) {
    const context = await browser.newContext({
      baseURL,
      viewport: { width: 320, height: 640 },
      locale: "en-CA",
      timezoneId: "America/Toronto",
      storageState: p.state || undefined,
    });
    const page = await context.newPage();
    try {
      await page.goto(p.path, { waitUntil: "networkidle", timeout: 30_000 });
      await page.waitForTimeout(300);
      const { scrollWidth, innerWidth } = await page.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        innerWidth: window.innerWidth,
      }));
      if (scrollWidth > innerWidth) {
        failures++;
        // Name the widest offenders, so the failure says what to fix.
        const culprits = await page.evaluate(() =>
          [...document.querySelectorAll("body *")]
            .filter((el) => el.getBoundingClientRect().right > window.innerWidth + 1)
            // Inside a scroll container the overflow is contained, not the page's.
            .filter((el) => {
              for (let a = el.parentElement; a; a = a.parentElement) {
                const o = getComputedStyle(a).overflowX;
                if (o === "auto" || o === "scroll" || o === "hidden") return false;
              }
              return true;
            })
            .slice(0, 6)
            .map((el) => `${el.tagName.toLowerCase()}${el.id ? "#" + el.id : ""}` +
              `${el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\s+/).join(".") : ""}`));
        console.error(
          `OVERFLOW ${p.name} at 320px: scrollWidth ${scrollWidth} > innerWidth ${innerWidth}` +
          `\n    first elements past the edge: ${culprits.join(", ")}`);
      } else {
        console.log(`no overflow at 320px: ${p.name}`);
      }
    } catch (err) {
      failures++;
      console.error(`FAILED overflow check ${p.name}: ${err.message}`);
    } finally {
      await context.close();
    }
  }

  // Desktop captures keep their historic names; the phone width adds a
  // suffix and covers the pages built from the shared list rows.
  const PHONE_PAGES = new Set(PHONE_PAGE_NAMES);
  const VIEWPORTS = [
    { suffix: "", width: 1280, height: 900, only: null },
    { suffix: "--w375", width: 375, height: 812, only: PHONE_PAGES },
  ];
  for (const scheme of ["light", "dark"]) {
   for (const vp of VIEWPORTS) {
    for (const p of PAGES) {
      if (vp.only && !vp.only.has(p.name)) continue;
      const context = await browser.newContext({
        baseURL,
        colorScheme: scheme,
        viewport: { width: vp.width, height: vp.height },
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
          // The per-course handle is two words drawn at random, so its LENGTH
          // moves between runs. Freezing the text rather than masking the line
          // keeps its label and typography under test and only gives up the
          // two words themselves — a mask here would be sized by the text and
          // so would move anyway, which is the trap the comment above records.
          document.querySelectorAll("[data-avatar-handle]").forEach((el) => {
            el.textContent = "Class handle: Aaaaaaa Bbbbbb";
          });
          // Which seasonal ring is open depends on today's Waterloo term, so
          // one of the three swatches would lose its dimming every January,
          // May and September. Their names already read the same on every
          // date; disabling all three pins the dimming too.
          document
            .querySelectorAll('input[data-av-season]:not([data-av-season=""])')
            .forEach((el) => {
              el.disabled = true;
            });
          // The Users table sorts by last seen, and last_seen_at refreshes at
          // most once a minute per user. So which of the two seeded users was
          // seen last depends on where those refreshes fall in the capture
          // passes, and the two rows swapped in one pass of a run and not the
          // others. Pin the order the baselines hold: the student, whom the
          // seed logs in last, first. Ordering by name, descending, gives that
          // order without reading the timestamps that move.
          document.querySelectorAll("#users-table tbody").forEach((body) => {
            const name = (row) => row.querySelector(".item-main")?.dataset.sortValue ?? "";
            [...body.rows]
              .sort((a, b) => name(b).localeCompare(name(a)))
              .forEach((row) => body.appendChild(row));
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
        const file = path.join(outDir, `${p.name}${vp.suffix}--${scheme}.png`);
        await page.screenshot({
          path: file,
          fullPage: true,
          animations: "disabled",
          // Visible matches only. Chromium lays out the content of a CLOSED
          // <details>, so an unfiltered mask paints boxes over elements the
          // page does not show (the account page's handle panel draws three
          // avatars that way) and bakes them into the baseline.
          mask: MASKS.map((sel) => page.locator(sel).filter({ visible: true })),
          maskColor: "#FF00FF",
        });
        console.log(`captured ${p.name}${vp.suffix}--${scheme}`);
      } catch (err) {
        failures++;
        console.error(`FAILED to capture ${p.name}${vp.suffix}--${scheme}: ${err.message}`);
      } finally {
        await context.close();
      }
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
