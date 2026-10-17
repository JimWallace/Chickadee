// workbench-shell-check.mjs — the workbench shell in the real editor
// (notebook views NB6, frame 18c).
//
// Seeds an assignment with two sections, a solution and a test that links to
// no cell, opens the workbench as its instructor, and asserts:
//
//   1. the rail lists each section and its items, then "Not linked to a
//      cell", with "3 checks · 3 pts";
//   2. a rail item reveals its cell in the editor (ck:active-cell);
//   3. ✎ opens the Details sheet: focus moves into it, Escape closes it, and
//      focus returns to ✎;
//   4. a setting saved from a sheet keeps the page and the kernel: a name
//      defined before the save still prints after it;
//   5. under 1300px the rail is behind ☰ Suite, which opens it over the
//      notebook; Escape closes it and focus returns to the button.
//
// SMOKE_SCREENSHOT_DIR, when set, receives a screenshot after each step.
//
// Usage:   node workbench-shell-check.mjs <baseURL>
// Exit 0 = healthy; exit 1 = broken (details printed).

import { chromium, webkit, firefox } from "playwright";
import fs from "node:fs";
import path from "node:path";
import { seedInstructorAssignment } from "./seed.mjs";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
const STEP_MS = 30_000;
const shots = process.env.SMOKE_SCREENSHOT_DIR;

function fail(reason) {
  console.log(`SHELL FAIL — ${reason}`);
  process.exit(1);
}

const code = (id, lines) => ({ cell_type: "code", id, metadata: {}, outputs: [], execution_count: null, source: lines });
const NOTEBOOK = {
  nbformat: 4,
  nbformat_minor: 5,
  metadata: { kernelspec: { name: "xpython", display_name: "Python (xeus-python)", language: "python" } },
  cells: [
    { cell_type: "markdown", id: "h1", source: ["## Task 1: Count\n"], metadata: {} },
    code("count", ["def count_to(n):\n", "    return list(range(n))\n"]),
    { cell_type: "markdown", id: "h2", source: ["## Task 2: Total\n"], metadata: {} },
    code("total", ["def total(xs):\n", "    return sum(xs)\n"]),
  ],
};

const MANIFEST = {
  schemaVersion: 1,
  gradingMode: "browser",
  language: "python",
  requiredFiles: [],
  sections: [
    { id: "s1", name: "Task 1: Count", variables: [] },
    { id: "s2", name: "Task 2: Total", variables: [] },
  ],
  testSuites: [
    { tier: "public", script: "test_count.py", sectionID: "s1", points: 1 },
    { tier: "public", script: "test_total.py", sectionID: "s2", points: 1 },
    { tier: "public", script: "test_loose.py", points: 1 },
  ],
  timeLimitSeconds: 10,
  makefile: null,
};

const FILES = {
  "test_count.py": "assert count_to(3) == [0, 1, 2]\n",
  "test_total.py": "assert total([1, 2]) == 3\n",
  "test_loose.py": "print('ok')\n",
};

async function main() {
  console.log(`Browser engine: ${browserName}`);
  let seeded;
  try {
    seeded = await seedInstructorAssignment(baseURL, {
      notebook: NOTEBOOK, files: FILES, manifest: MANIFEST, title: "Shell Lab",
    });
  } catch (e) {
    return fail(`seeding failed: ${(e && e.message) || e}`);
  }
  const launchOptions =
    browserName === "chromium" ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false } : { headless: true };
  if (process.env.SMOKE_BROWSER_PATH) launchOptions.executablePath = process.env.SMOKE_BROWSER_PATH;
  const browser = await browserType.launch(launchOptions);
  const context = await browser.newContext({ storageState: seeded.storageState, viewport: { width: 1440, height: 900 } });
  await context.addInitScript(() => {
    if (window.top !== window) return;
    window.__ck = [];
    window.addEventListener("message", (e) => {
      const d = e && e.data;
      if (d && typeof d.ck === "string" && d.ck.startsWith("ck:")) window.__ck.push(d);
    });
  });
  const page = await context.newPage();
  context.on("page", (p) => p.close().catch(() => {}));
  const finish = async (exitCode) => { await browser.close(); process.exit(exitCode); };
  let step = 0;
  const shot = async (name) => {
    if (!shots) return;
    fs.mkdirSync(shots, { recursive: true });
    step += 1;
    await page.screenshot({ path: path.join(shots, `${String(step).padStart(2, "0")}-${browserName}-${name}.png`) });
  };
  const events = (kind) => page.evaluate((k) => window.__ck.filter((d) => d.ck === k), kind);
  const waitFor = async (label, predicate, timeout = STEP_MS) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (await predicate()) return;
      await page.waitForTimeout(250);
    }
    throw new Error(`timed out: ${label}`);
  };
  const editor = () => page.frameLocator("#jl-frame");
  const editorFrame = () => page.frames().find((f) => f.url().includes("/jupyterlite/notebooks/"));
  const focusedID = () => page.evaluate(() => document.activeElement && document.activeElement.id);

  try {
    await page.goto(`${baseURL}/instructor/${seeded.assignmentID}/workbench?file=assignment&view=personalized`, {
      waitUntil: "domcontentloaded",
    });
    await waitFor("ck:kernel idle", async () => (await events("ck:kernel")).some((d) => d.status === "idle"), KERNEL_BOOT_MS);

    // (1) The rail.
    const items = page.locator("#wb-rail .outline-row[data-item-id]");
    await waitFor("three rail items", async () => (await items.count()) === 3);
    const captions = await page.locator("#wb-rail-suite .outline-caption").allTextContents();
    const totals = await page.locator("#wb-rail-totals").textContent();
    console.log(`rail: ${captions.join(" | ")}; ${totals}`);
    if (captions.join("|") !== "Task 1|Task 2|Not linked to a cell") return fail(`rail captions ${captions}`);
    if (totals !== "3 checks · 3 pts") return fail(`rail totals ${totals}`);
    await shot("rail");

    // (2) A rail item reveals its cell.
    await page.locator('#wb-rail .outline-row[data-item-id="test_total.py"]').click();
    await waitFor("ck:active-cell names total", async () =>
      (await events("ck:active-cell")).some((d) => d.names.includes("total")));

    // (3) The Details sheet: focus in, Escape out, focus back.
    const pencil = page.locator('.wb-appbar [data-wb-open-sheet="details"]');
    await pencil.click();
    await page.waitForSelector("#wb-sheet:not([hidden])", { timeout: 5000 });
    if ((await focusedID()) !== "wb-sheet-close") return fail(`focus did not move into the sheet: ${await focusedID()}`);
    if (!(await page.locator('#wb-sheet input[name="assignmentName"]').isVisible())) {
      return fail("the Details sheet does not show the name field");
    }
    await shot("details");
    await page.keyboard.press("Escape");
    if (!(await page.locator("#wb-sheet").isHidden())) return fail("Escape did not close the sheet");
    const backOnPencil = await page.evaluate(() =>
      document.activeElement && document.activeElement.getAttribute("data-wb-open-sheet") === "details");
    if (!backOnPencil) return fail("focus did not return to ✎");

    // (4) A saved setting keeps the kernel.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "count_to" }));
    const ran = async () => (await events("ck:cell-ran")).length;
    let n = await ran();
    await page.locator('[data-nb-commands="notebook:run-cell-and-select-next"]').click();
    await waitFor("count_to defined", async () => (await ran()) > n);
    const starts = (await events("ck:kernel")).filter((d) => d.status === "starting").length;
    await editorFrame().evaluate(() => { window.__ckSameDocument = true; });
    await pencil.click();
    await page.fill('#wb-sheet input[name="assignmentName"]', "Shell Lab renamed");
    await page.locator("#wb-save").click();
    await waitFor("saved", async () => (await page.locator("#wb-save-status").textContent()) === "Saved");
    if (!page.url().includes("/workbench")) return fail(`the save left the workbench: ${page.url()}`);
    if (!(await editorFrame().evaluate(() => window.__ckSameDocument === true))) return fail("the save reloaded the editor");
    if ((await events("ck:kernel")).filter((d) => d.status === "starting").length !== starts) {
      return fail("the save restarted the kernel");
    }
    await page.keyboard.press("Escape");
    await page.locator('[data-nb-commands="notebook:insert-cell-below notebook:change-cell-to-code"]').click();
    await editor().locator(".jp-Cell.jp-mod-active .cm-content").click();
    await page.keyboard.type("print(count_to(3))");
    n = await ran();
    await page.keyboard.press("Shift+Enter");
    await waitFor("print ran", async () => (await ran()) > n);
    const out = await editor().locator(".jp-OutputArea-output").allTextContents();
    console.log(`after the save: ${out.join(" | ").trim()}`);
    if (!out.some((o) => o.includes("[0, 1, 2]"))) return fail("the kernel lost count_to across the save");
    await shot("saved");

    // (5) Under 1300px: ☰ Suite.
    await page.setViewportSize({ width: 1100, height: 800 });
    await waitFor("the rail folds", async () => !(await page.locator("#wb-rail").isVisible()));
    await page.locator("#wb-rail-toggle").click();
    if (!(await page.locator("#wb-rail").isVisible())) return fail("☰ Suite did not open the rail");
    if ((await page.locator("#wb-rail-toggle").getAttribute("aria-expanded")) !== "true") {
      return fail("☰ Suite does not say that it is open");
    }
    await shot("folded-open");
    await page.keyboard.press("Escape");
    if (await page.locator("#wb-rail").isVisible()) return fail("Escape did not close the rail");
    if ((await focusedID()) !== "wb-rail-toggle") return fail("focus did not return to ☰ Suite");

    console.log("SHELL OK");
    return finish(0);
  } catch (e) {
    await shot("failure").catch(() => {});
    console.log(`SHELL FAIL — ${(e && e.message) || e}`);
    return finish(1);
  }
}

main();
