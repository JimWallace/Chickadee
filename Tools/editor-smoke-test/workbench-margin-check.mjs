// workbench-margin-check.mjs — the test cards beside the notebook in the
// real editor (notebook views NB7, frame 18c).
//
// Seeds an assignment with two sections, a solution and a test that links to
// no cell, opens the workbench as its instructor, and asserts:
//
//   1. a section card sits beside each `## ` heading, and each test's card
//      beside the cell it is linked to, in a column at the cell's top right;
//   2. a cell is at least as tall as its cards, and a card stays at its
//      cell's top after lines are added above it;
//   3. a rail item selects its card: the card opens with the test's source
//      and Edit test, Run again and Pin to a cell;
//   4. Pin to a cell, then a click on another code cell, saves the pin, and
//      the card moves beside that cell;
//   5. under 1100px of notebook the cards fold into a strip under the cell,
//      which opens into them.
//
// The harness starts no native runner, so no test has a result on the
// solution here; the issue lines are covered by the extension's unit tests.
//
// SMOKE_SCREENSHOT_DIR, when set, receives a screenshot after each step.
//
// Usage:   node workbench-margin-check.mjs <baseURL>
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
  console.log(`MARGIN FAIL — ${reason}`);
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
    code("summary", ["def summary(xs):\n", "    return total(xs) / len(xs)\n"]),
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
    { tier: "secret", script: "test_count_big.py", sectionID: "s1", points: 2 },
    { tier: "public", script: "test_total.py", sectionID: "s2", points: 1 },
    { tier: "public", script: "test_loose.py", points: 1 },
  ],
  timeLimitSeconds: 10,
  makefile: null,
};

const FILES = {
  "test_count.py": "assert count_to(3) == [0, 1, 2]\n",
  "test_count_big.py": "assert len(count_to(100)) == 100\n",
  "test_total.py": "assert total([1, 2]) == 3\n",
  "test_loose.py": "print('ok')\n",
};

async function main() {
  console.log(`Browser engine: ${browserName}`);
  let seeded;
  try {
    seeded = await seedInstructorAssignment(baseURL, {
      notebook: NOTEBOOK, files: FILES, manifest: MANIFEST, title: "Margin Lab",
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

  const cardsBeside = (cellIndex) => editor().locator(".jp-Notebook .jp-Cell").nth(cellIndex).locator(":scope > .ck-margin .ck-card");
  const cardIDs = async (cellIndex) => cardsBeside(cellIndex).evaluateAll((els) => els.map((e) => e.dataset.itemId));

  try {
    await page.goto(`${baseURL}/instructor/${seeded.assignmentID}/workbench?file=assignment&view=personalized`, {
      waitUntil: "domcontentloaded",
    });
    await waitFor("ck:kernel idle", async () => (await events("ck:kernel")).some((d) => d.status === "idle"), KERNEL_BOOT_MS);

    // (1) The cards beside their cells.
    await waitFor("cards beside count_to", async () => (await cardIDs(1)).length === 2);
    console.log(`beside count_to: ${await cardIDs(1)}; beside total: ${await cardIDs(3)}`);
    if ((await cardIDs(1)).join(",") !== "test_count.py,test_count_big.py") return fail(`count_to cards ${await cardIDs(1)}`);
    if ((await cardIDs(3)).join(",") !== "test_total.py") return fail(`total cards ${await cardIDs(3)}`);
    const headings = await editor().locator(".ck-section-card .ck-task-label").allTextContents();
    if (headings.join("|") !== "Task 1|Task 2") return fail(`section cards ${headings}`);
    const linked = await editor().locator(".jp-Cell").nth(1).locator(".ck-linked").textContent();
    if (linked !== "Linked by count_to") return fail(`linked line ${linked}`);
    const geometry = async (i) => editorFrame().evaluate((index) => {
      const cell = document.querySelectorAll(".jp-Notebook .jp-Cell")[index];
      const margin = cell.querySelector(":scope > .ck-margin");
      const c = cell.getBoundingClientRect();
      const m = margin.getBoundingClientRect();
      const input = cell.querySelector(".jp-InputArea").getBoundingClientRect();
      return { cellTop: c.top, cellBottom: c.bottom, cellRight: c.right, top: m.top, bottom: m.bottom, left: m.left, right: m.right, inputRight: input.right };
    }, i);
    let g = await geometry(1);
    console.log(`geometry: ${JSON.stringify(g)}`);
    if (Math.abs(g.top - g.cellTop) > 6) return fail("the cards are not at their cell's top");
    if (g.left < g.inputRight) return fail("the cards overlap the cell's code");
    if (g.right > g.cellRight + 1) return fail("the cards spill past the cell");
    // (2) The cell is as tall as its cards.
    if (g.bottom > g.cellBottom + 1) return fail("the cell is shorter than its cards");
    await shot("cards");

    // (3) A rail item selects its card.
    await page.locator('#wb-rail .outline-row[data-item-id="test_total.py"]').click();
    const card = editor().locator('.ck-card[data-item-id="test_total.py"]');
    await waitFor("card selected", async () => (await card.getAttribute("data-selected")) === "true");
    const source = await card.locator(".ck-source").textContent();
    if (!source.includes("assert total([1, 2]) == 3")) return fail(`card source ${source}`);
    const actions = await card.locator(".ck-action").allTextContents();
    if (actions.join("|") !== "Edit test|Run again|Pin to a cell") return fail(`card actions ${actions}`);
    await shot("selected");

    // (2b) Lines added above keep the cards at their cell's top.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "count_to" }));
    await editor().locator(".jp-CodeCell").first().locator(".cm-content").click();
    await page.keyboard.press("Control+End");
    await page.keyboard.type("\n# one\n# two\n# three");
    await page.waitForTimeout(1200);
    g = await geometry(3);
    if (Math.abs(g.top - g.cellTop) > 6) return fail("after an edit the cards left their cell's top");

    // (4) Pin test_total to summary.
    await card.locator(".ck-action", { hasText: "Pin to a cell" }).click();
    await editor().locator(".jp-CodeCell").nth(2).locator(".jp-InputArea").click();
    await waitFor("pinned beside summary", async () => (await cardIDs(4)).includes("test_total.py"));
    if ((await cardIDs(3)).includes("test_total.py")) return fail("the pinned card is still beside total");
    const pinnedStatus = await page.locator("#wb-save-status").textContent();
    console.log(`after the pin: ${pinnedStatus}`);
    if (pinnedStatus !== "Pinned to summary") return fail(`pin status ${pinnedStatus}`);
    await shot("pinned");

    // (5) The fold.
    await page.setViewportSize({ width: 1000, height: 900 });
    await waitFor("folded", async () => editorFrame().evaluate(() => document.body.classList.contains("ck-margin-fold")));
    const strip = editor().locator(".jp-Cell").nth(1).locator(".ck-strip");
    const stripText = (await strip.textContent()).replace(/\s+/g, " ").trim();
    console.log(`strip: ${stripText}`);
    if (!stripText.includes("2 checks · 3 pts") || !stripText.includes("Linked by count_to")) return fail(`strip ${stripText}`);
    if (await cardsBeside(1).first().isVisible()) return fail("the folded cards show before the strip opens");
    await strip.click();
    if (!(await cardsBeside(1).first().isVisible())) return fail("the strip does not open into the cards");
    await shot("folded");

    console.log("MARGIN OK");
    return finish(0);
  } catch (e) {
    await shot("failure").catch(() => {});
    console.log(`MARGIN FAIL — ${(e && e.message) || e}`);
    return finish(1);
  }
}

main();
