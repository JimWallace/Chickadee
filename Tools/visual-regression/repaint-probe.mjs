// Does a background table repaint survive contact with the shared widgets?
//
// The visual-regression capture screenshots ~300ms after load, so it never
// sees a poll repaint. That leaves the interaction of four consolidations
// unverified by anything: table-poll.js swaps in server-rendered rows (S3),
// which must still resolve sprite icons (S4), still carry the sort the user
// chose (S2), and still respect the filter box (S1).
//
// Each of those fails SILENTLY and in a way a screenshot taken too early
// cannot catch: icons render as empty boxes, the sort reverts to server
// order, the filter forgets what was typed.
//
// Usage: node repaint-probe.mjs <baseURL> <storageStateJSON>
import { chromium } from "playwright";
import fs from "node:fs";

const baseURL = process.argv[2];
const statePath = process.argv[3];
if (!baseURL) {
  console.error("usage: node repaint-probe.mjs <baseURL> <stateFile>");
  process.exit(2);
}

const browser = await chromium.launch();
const context = await browser.newContext({
  baseURL,
  storageState: statePath && fs.existsSync(statePath) ? statePath : undefined,
});
const page = await context.newPage();
let failures = 0;
const check = (ok, label, detail) => {
  console.log(`${ok ? "✓" : "✘"} ${label}${ok ? "" : ` — ${detail}`}`);
  if (!ok) failures++;
};

await page.goto("/instructor/students", { waitUntil: "networkidle" });

// An icon-only button must actually paint a glyph. A <use> that resolves to
// nothing still lays out at its CSS size, so measure the SYMBOL, not the box.
const iconResolves = async () =>
  page.evaluate(() => {
    const use = document.querySelector("#enrolled-students-table .icon use");
    if (!use) return { found: false };
    const href = use.getAttribute("href") || "";
    const symbol = document.querySelector(href);
    const box = use.ownerSVGElement.getBoundingClientRect();
    return { found: true, href, symbolExists: !!symbol, w: box.width, h: box.height };
  });

const before = await iconResolves();
check(before.found && before.symbolExists && before.w > 0,
  "sprite icon resolves on first paint", JSON.stringify(before));

// Sort by Username so the repaint has a non-default sort to restore, then
// blur. Clicking leaves focus on the header button, which is INSIDE the
// table — and the poll deliberately suppresses itself while focus is in the
// table, so it would never fire. Blurring is what a person does when they
// stop interacting and let the page tick over.
await page.click('th[data-sort-key="username"] .sort-header');
await page.evaluate(() => document.activeElement.blur());
const sortedBefore = await page.evaluate(() =>
  Array.from(document.querySelectorAll("#enrolled-students-table tbody tr"))
    .map((r) => (r.cells[1]?.textContent || "").trim()));
const ariaBefore = await page.getAttribute('th[data-sort-key="username"]', "aria-sort");
check(ariaBefore === "ascending", "aria-sort is set on the sorted column", String(ariaBefore));

// Stamp a row, then WAIT FOR the stamp to disappear rather than sleeping a
// fixed span. The poll ticks every 5s, but a fixed sleep turns a busy CI
// runner into a false failure — waiting on the condition costs the same
// wall-clock when things are healthy and does not lie when they are slow.
//
// The stamp goes on a ROW, not on the <tbody>: the swap assigns
// tbody.innerHTML, which replaces the children and leaves the tbody element
// (and anything set on it) untouched.
const REPAINT_TIMEOUT_MS = 30000;
const awaitRepaint = async () => {
  const stamped = await page.evaluate(() => {
    const row = document.querySelector("#enrolled-students-table tbody tr");
    if (!row) return false;
    row.dataset.probeStamp = "1";
    return true;
  });
  if (!stamped) return { stamped: false, repainted: false };
  try {
    await page.waitForFunction(
      () => !document.querySelector("#enrolled-students-table tbody tr[data-probe-stamp]"),
      null, { timeout: REPAINT_TIMEOUT_MS });
    return { stamped: true, repainted: true };
  } catch {
    return { stamped: true, repainted: false };
  }
};

const first = await awaitRepaint();
check(first.stamped && first.repainted, "a background repaint actually happened",
  first.stamped
    ? `the stamped row was never replaced within ${REPAINT_TIMEOUT_MS}ms`
    : "no row to stamp");

const after = await iconResolves();
check(after.found && after.symbolExists && after.w > 0,
  "sprite icon still resolves after the repaint", JSON.stringify(after));

const sortedAfter = await page.evaluate(() =>
  Array.from(document.querySelectorAll("#enrolled-students-table tbody tr"))
    .map((r) => (r.cells[1]?.textContent || "").trim()));
check(JSON.stringify(sortedAfter) === JSON.stringify(sortedBefore),
  "the user's sort survives the repaint", `${JSON.stringify(sortedBefore)} -> ${JSON.stringify(sortedAfter)}`);

const ariaAfter = await page.getAttribute('th[data-sort-key="username"]', "aria-sort");
check(ariaAfter === "ascending", "aria-sort survives the repaint", String(ariaAfter));

// Filter to something that matches nothing, then let a repaint land on it.
// The filter input is readonly until first focus (the shared component's
// autofill suppression), which is exactly how a person meets it: click, then
// type. `fill` alone refuses, because it checks editability before focusing.
await page.click("#enrolled-filter");
await page.fill("#enrolled-filter", "zzz-no-such-student");
await page.evaluate(() => document.getElementById("enrolled-filter").blur());

// Same shape as above: assert against a repaint that demonstrably landed,
// not against elapsed time. If no repaint arrives, that is its own failure —
// reported as such rather than passing because the rows happened to stay
// hidden while nothing was replacing them.
const second = await awaitRepaint();
const hiddenAfter = await page.evaluate(() =>
  Array.from(document.querySelectorAll("#enrolled-students-table tbody tr"))
    .every((r) => r.hidden));
check(second.repainted && hiddenAfter, "the filter survives the repaint",
  second.repainted
    ? "rows reappeared despite a non-matching filter"
    : "no repaint landed while the filter was set, so the check proved nothing");

await browser.close();
console.log(failures === 0
  ? "repaint-probe: OK"
  : `repaint-probe: ${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
