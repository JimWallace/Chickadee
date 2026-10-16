// notebook-toolbar-check.mjs — the Chickadee JupyterLite extension and the
// page's one toolbar, in the real editor (notebook views NB2).
//
// Seeds a Python assignment, opens the real student page, and asserts:
//
//   1. the extension loads: ck:kernel reaches idle, the boot diagnostics still
//      report kernel_idle, and the loading panel closes;
//   2. the Chickadee theme is on (body[data-ck-theme] in the editor), and it
//      follows the page into dark mode;
//   3. Notebook 7's top area, menu bar and notebook toolbar are hidden;
//   4. + Code and + Text insert a code and a text cell;
//   5. ▶ Run and Shift+Enter run a cell (ck:cell-ran ok), and Run all runs them;
//   6. ck:active-cell names what the cell defines, from the server's patterns;
//   7. ⋯ → Clear outputs clears the outputs.
//
// SMOKE_SCREENSHOT_DIR, when set, receives a screenshot after each step.
//
// Usage:   node notebook-toolbar-check.mjs <baseURL>
// Exit 0 = healthy; exit 1 = broken (details printed).

import { chromium, webkit, firefox } from "playwright";
import fs from "node:fs";
import path from "node:path";
import { seedAssignment } from "./seed.mjs";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
const STEP_MS = 30_000;
const shots = process.env.SMOKE_SCREENSHOT_DIR;

function fail(reason) {
  console.log(`TOOLBAR FAIL — ${reason}`);
  process.exit(1);
}

const NOTEBOOK = {
  nbformat: 4,
  nbformat_minor: 5,
  metadata: { kernelspec: { name: "xpython", display_name: "Python (xeus-python)", language: "python" } },
  cells: [
    { cell_type: "markdown", id: "intro", source: ["## Task 1: Count\n"], metadata: {} },
    {
      cell_type: "code", id: "count", metadata: {}, outputs: [], execution_count: null,
      source: ["GOAL = 3\n", "def count_to(n):\n", "    return list(range(n))\n", "print(count_to(GOAL))\n"],
    },
  ],
};

const MANIFEST = {
  schemaVersion: 1,
  gradingMode: "browser",
  language: "python",
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }],
  timeLimitSeconds: 10,
  makefile: null,
};

async function main() {
  console.log(`Browser engine: ${browserName}`);
  let seeded;
  try {
    seeded = await seedAssignment(baseURL, {
      notebook: NOTEBOOK, files: { "test_public.py": 'print("ok")\n' }, manifest: MANIFEST,
    });
  } catch (e) {
    return fail(`seeding failed: ${(e && e.message) || e}`);
  }
  const launchOptions =
    browserName === "chromium" ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false } : { headless: true };
  if (process.env.SMOKE_BROWSER_PATH) launchOptions.executablePath = process.env.SMOKE_BROWSER_PATH;
  const browser = await browserType.launch(launchOptions);
  const context = await browser.newContext({ storageState: seeded.storageState, colorScheme: "light" });
  await context.addInitScript(() => {
    if (window.top !== window) return;
    window.__ck = [];
    window.addEventListener("message", (e) => {
      const d = e && e.data;
      if (d && typeof d.ck === "string" && (d.ck.startsWith("ck:") || d.ck === "kernel-diag")) window.__ck.push(d);
    });
  });
  const page = await context.newPage();
  context.on("page", (p) => p.close().catch(() => {}));
  const finish = async (code) => { await browser.close(); process.exit(code); };
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

  try {
    await page.goto(`${baseURL}/testsetups/${seeded.setupID}/notebook`, { waitUntil: "domcontentloaded" });
    if (/\/login/.test(page.url())) return fail("redirected to login");

    // (1) The extension is loaded and reports the kernel.
    await waitFor("ck:kernel idle", async () => (await events("ck:kernel")).some((d) => d.status === "idle"), KERNEL_BOOT_MS);
    const chip = await page.locator("#nb-kernel-chip").getAttribute("data-state");
    console.log(`kernel chip: ${chip}`);
    if (chip !== "idle" && chip !== "busy") return fail(`kernel chip reads ${chip}, not idle`);
    // The hidden notebook toolbar keeps the execution indicator, so the boot
    // diagnostics still see the kernel come up, and the loading panel goes.
    await waitFor("kernel-diag kernel_idle", async () =>
      (await events("kernel-diag")).some((d) => d.kind === "kernel_phase" && d.source === "kernel_idle"));
    await waitFor("loading panel closed", async () => !(await page.locator("#nb-boot").isVisible()));
    await shot("booted");

    // (2) The theme, light then dark.
    const frame = editorFrame();
    if (!frame) return fail("no editor frame");
    await waitFor("light theme", async () => (await frame.evaluate(() => document.body.dataset.ckTheme)) === "light");
    await page.emulateMedia({ colorScheme: "dark" });
    await waitFor("dark theme", async () => (await frame.evaluate(() => document.body.dataset.ckTheme)) === "dark");
    await shot("dark");
    await page.emulateMedia({ colorScheme: "light" });
    await waitFor("light theme again", async () => (await frame.evaluate(() => document.body.dataset.ckTheme)) === "light");

    // (3) The editor's own chrome is hidden.
    const chrome = await frame.evaluate(() => {
      const visible = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden";
      return {
        menuBar: visible(document.querySelector(".lm-MenuBar")),
        topBar: visible(document.querySelector("#top-panel")),
        notebookToolbar: visible(document.querySelector(".jp-NotebookPanel-toolbar")),
      };
    });
    console.log(`editor chrome visible: ${JSON.stringify(chrome)}`);
    if (chrome.menuBar || chrome.topBar || chrome.notebookToolbar) return fail(`editor chrome still visible: ${JSON.stringify(chrome)}`);

    // (4) + Code and + Text.
    const cells = () => editor().locator(".jp-Notebook .jp-Cell");
    const cellTypes = () => editor().locator(".jp-Notebook .jp-Cell").evaluateAll((els) =>
      els.map((el) => (el.classList.contains("jp-MarkdownCell") ? "markdown" : el.classList.contains("jp-CodeCell") ? "code" : "?")));
    const tally = (list, type) => list.filter((t) => t === type).length;
    const typesBefore = await cellTypes();
    const before = typesBefore.length;
    await page.locator('[data-nb-commands="notebook:insert-cell-below notebook:change-cell-to-code"]').click();
    await waitFor("+ Code adds a cell", async () => (await cells().count()) === before + 1);
    await page.locator('[data-nb-commands="notebook:insert-cell-below notebook:change-cell-to-markdown"]').click();
    await waitFor("+ Text adds a cell", async () => (await cells().count()) === before + 2);
    // Each inserts below the active cell, so count by type, not by place.
    const types = await cellTypes();
    console.log(`cell types: ${typesBefore.join(",")} -> ${types.join(",")}`);
    if (tally(types, "code") !== tally(typesBefore, "code") + 1 || tally(types, "markdown") !== tally(typesBefore, "markdown") + 1) {
      return fail(`+ Code and + Text did not add one code and one text cell: ${types}`);
    }
    await shot("inserted");

    // (5) ▶ Run on the code cell, Shift+Enter, then Run all.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "count_to" }));
    const ran = async () => (await events("ck:cell-ran")).length;
    let n = await ran();
    await page.locator('[data-nb-commands="notebook:run-cell-and-select-next"]').click();
    await waitFor("▶ Run", async () => (await ran()) > n);
    const last = (await events("ck:cell-ran")).at(-1);
    if (last.status !== "ok") return fail(`▶ Run reported ${last.status}`);
    const output = await editor().locator(".jp-OutputArea-output").first().innerText();
    console.log(`output: ${output.trim()}`);
    if (!output.includes("[0, 1, 2]")) return fail(`unexpected output ${output}`);

    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { index: 1 }));
    n = await ran();
    await editor().locator(".jp-Notebook .jp-Cell").nth(1).click();
    await page.keyboard.press("Shift+Enter");
    await waitFor("Shift+Enter", async () => (await ran()) > n);

    n = await ran();
    await page.locator('[data-nb-commands="notebook:run-all-cells"]').click();
    await waitFor("Run all", async () => (await ran()) >= n + 2);
    await shot("ran");

    // (6) The active cell's names come from the server's patterns.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { index: 0 }));
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "GOAL" }));
    await waitFor("ck:active-cell names", async () =>
      (await events("ck:active-cell")).some((d) => d.names.includes("count_to") && d.names.includes("GOAL")));

    // (7) ⋯ → Clear outputs.
    await page.locator('summary[aria-label="More actions for the notebook"]').click();
    await page.locator('[data-nb-commands="notebook:clear-all-cell-outputs"]').click();
    await waitFor("Clear outputs", async () => (await editor().locator(".jp-OutputArea-output").count()) === 0);
    await shot("cleared");

    const saved = await page.locator("#nb-save-state").textContent();
    console.log(`save state: ${saved}`);
    console.log("TOOLBAR OK");
    return finish(0);
  } catch (e) {
    await shot("failure").catch(() => {});
    console.log(`TOOLBAR FAIL — ${(e && e.message) || e}`);
    return finish(1);
  }
}

main();
