// notebook-guide-check.mjs — the student guide in the real editor (notebook
// views NB4, frame 18a).
//
// Seeds a Python assignment with two suite sections, opens the real student
// page, and asserts:
//
//   1. the outline beside the editor has one row per task and the attempt card;
//   2. the extension draws a task header above each `## ` heading, with the
//      starter pill, and a checks line with the public checks and the hidden
//      count;
//   3. an edit to a task's cell changes its pill and its outline row, after
//      the edit debounce;
//   4. a row click moves the editor, and ck:active-cell names that task;
//   5. the Reflection row turns Written when its cell gets text;
//   6. a renamed function gives "Can't find" on its checks line;
//   7. at 900px the outline is a row of chips, each at least 44px tall.
//
// SMOKE_SCREENSHOT_DIR, when set, receives a screenshot after each step.
//
// Usage:   node notebook-guide-check.mjs <baseURL>
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
  console.log(`GUIDE FAIL — ${reason}`);
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
    code("total", ["def total(xs):\n", "    return 0\n"]),
    { cell_type: "markdown", id: "refl", source: [], metadata: { tags: ["reflection"] } },
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
    { tier: "public", script: "test_count.py", sectionID: "s1", points: 2 },
    { tier: "public", script: "test_total.py", sectionID: "s2", points: 3 },
    { tier: "secret", script: "test_total_hidden.py", sectionID: "s2", points: 1 },
  ],
  timeLimitSeconds: 10,
  makefile: null,
};

const FILES = {
  "test_count.py": "from assignment import count_to\nassert count_to(3) == [0, 1, 2]\n",
  "test_total.py": "from assignment import total\nassert total([1, 2]) == 3\n",
  "test_total_hidden.py": "from assignment import total\nassert total([]) == 0\n",
};

async function main() {
  console.log(`Browser engine: ${browserName}`);
  let seeded;
  try {
    seeded = await seedAssignment(baseURL, {
      notebook: NOTEBOOK, files: FILES, manifest: MANIFEST,
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

  const headers = () => editor().locator(".ck-task-header");
  const pills = () => headers().locator(".ck-pill").allInnerTexts();
  const rows = () => page.locator("#nb-outline .outline-row");

  try {
    await page.goto(`${baseURL}/testsetups/${seeded.setupID}/notebook`, { waitUntil: "domcontentloaded" });
    if (/\/login/.test(page.url())) return fail("redirected to login");
    await waitFor("ck:kernel idle", async () => (await events("ck:kernel")).some((d) => d.status === "idle"), KERNEL_BOOT_MS);

    // (1) The outline.
    await waitFor("outline rows", async () => (await rows().count()) === 3);
    const outline = await page.locator("#nb-outline").textContent();
    console.log(`outline: ${outline.replace(/\s+/g, " ").trim()}`);
    if (!outline.includes("Not submitted yet")) return fail("the attempt card does not say Not submitted yet");
    if (!outline.includes("1. Count") || !outline.includes("2. Total")) return fail("the rows do not name the tasks");
    await shot("outline");

    // (2) Headers and checks lines in the editor.
    await waitFor("two task headers and the reflection", async () => (await headers().count()) === 3).catch(async (e) => {
      // What the editor holds, so a failure on one engine can be read.
      const seen = await editorFrame().evaluate(() => ({
        cells: document.querySelectorAll(".jp-Notebook .jp-Cell").length,
        cellHeaders: document.querySelectorAll(".jp-Notebook .jp-CellHeader").length,
        hosts: document.querySelectorAll(".ck-guide-host").length,
        nodes: document.querySelectorAll(".ck-guide-node").length,
        labels: [...document.querySelectorAll(".ck-task-label")].map((n) => n.textContent),
        theme: document.body.dataset.ckTheme || null,
      })).catch((err) => `unreadable: ${err}`);
      console.log(`editor state: ${JSON.stringify(seen)}`);
      throw e;
    });
    const labels = await headers().locator(".ck-task-label").allTextContents();
    console.log(`headers: ${labels.join(" | ")}; pills: ${(await pills()).join(" | ")}`);
    if (labels.join("|") !== "Task 1|Task 2|Reflection") return fail(`header labels ${labels}`);
    // The header sits in the heading cell's own header widget.
    const inHeading = await editor().locator(".jp-MarkdownCell .jp-CellHeader .ck-task-header").count();
    if (inHeading !== 3) return fail(`${inHeading} headers sit in a markdown cell header, not 3`);
    if ((await pills())[1] !== "Still the starter code") return fail(`task 2 pill is ${(await pills())[1]}`);
    const checks = editor().locator(".jp-CodeCell .jp-CellFooter .ck-checks");
    await waitFor("two checks lines", async () => (await checks.count()) === 2);
    const second = await checks.nth(1).innerText();
    console.log(`task 2 checks: ${second.replace(/\s+/g, " ").trim()}`);
    if (!second.includes("Checked when you submit")) return fail("the checks line has no prefix");
    if (!second.includes("1 hidden test")) return fail("the checks line has no hidden count");
    if ((await checks.nth(1).locator(".ck-chip").count()) < 2) return fail("task 2 has no check chip");
    await shot("headers");
    // JupyterLab gives an empty header and footer zero height; a guide row
    // must take its own height, not spill onto the next cell.
    const overlaps = await editorFrame().evaluate(() => {
      const cells = [...document.querySelectorAll(".jp-Notebook .jp-Cell")];
      return cells.flatMap((cell, i) => {
        const next = cells[i + 1];
        const guide = [...cell.querySelectorAll(".ck-guide-node")];
        return next ? guide.filter((n) => n.getBoundingClientRect().bottom > next.getBoundingClientRect().top + 1).map(() => i) : [];
      });
    });
    if (overlaps.length) return fail(`a guide row overlaps the next cell, after cell ${overlaps}`);

    // (3) An edit changes the pill and the row, after the debounce.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "total" }));
    await editor().locator(".jp-CodeCell").nth(1).locator(".cm-content").click();
    await page.keyboard.press("Control+End");
    await page.keyboard.type("\n# edited");
    await waitFor("task 2 pill after the edit", async () => (await pills())[1] === "Not submitted yet");
    await waitFor("task 2 row after the edit", async () => (await rows().nth(1).getAttribute("data-status")) === "fresh");
    if ((await pills())[0] !== "Still the starter code") return fail(`task 1 pill changed to ${(await pills())[0]}`);
    await shot("edited");

    // (4) A row click reveals its task; the active cell names it.
    await rows().nth(0).click();
    await waitFor("ck:active-cell task s1", async () => (await events("ck:active-cell")).some((d) => d.task === "s1"));
    await waitFor("row 1 current", async () => (await rows().nth(0).getAttribute("aria-current")) === "step");

    // (5) The reflection row.
    if ((await rows().nth(2).getAttribute("data-status")) !== "empty") return fail("the reflection row is not Empty");
    await rows().nth(2).click();
    await page.keyboard.press("Enter");
    await page.keyboard.type("I chose the median.");
    await waitFor("reflection written", async () => (await rows().nth(2).getAttribute("data-status")) === "written");
    await page.keyboard.press("Escape");

    // (6) A renamed function.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "total" }));
    await editor().locator(".jp-CodeCell").nth(1).locator(".cm-content").click();
    await page.keyboard.press("Control+a");
    await page.keyboard.type("def total_sum(xs):\n    return 0");
    // With no anchor left, the checks line sits under the task's heading.
    const missing = editor().locator(".ck-missing");
    await waitFor("Can't find", async () => (await missing.count()) === 1);
    const missingText = await missing.textContent();
    console.log(`missing: ${missingText}`);
    if (missingText !== "Can't find total in your notebook") return fail(`missing text ${missingText}`);
    await shot("renamed");

    // (7) Narrow: chips.
    await page.setViewportSize({ width: 900, height: 800 });
    await waitFor("short labels", async () => await page.locator("#nb-outline .outline-short").first().isVisible());
    const heights = await rows().evaluateAll((els) => els.map((el) => el.getBoundingClientRect().height));
    console.log(`chip heights: ${heights.join(", ")}`);
    if (heights.some((h) => h < 44)) return fail(`a chip is under 44px: ${heights}`);
    await shot("narrow");

    console.log("GUIDE OK");
    return finish(0);
  } catch (e) {
    await shot("failure").catch(() => {});
    console.log(`GUIDE FAIL — ${(e && e.message) || e}`);
    return finish(1);
  }
}

main();
