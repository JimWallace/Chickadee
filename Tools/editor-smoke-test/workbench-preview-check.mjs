// workbench-preview-check.mjs — Preview as student in the real editor
// (notebook views NB6b).
//
// Seeds an assignment whose starter carries a `{{greeting}}` placeholder and a
// student enrolled in its course, opens the workbench as its instructor, and
// asserts:
//
//   1. "Preview as student ▾" lists the student;
//   2. picking the student swaps in the starter as they get it: the value in
//      place of the placeholder, read-only, the address names the preview,
//      and the menu button names the student;
//   3. the editor draws the student's task header in the state with no
//      attempt ("Still the starter code") and no test cards;
//   4. Save & validate in the preview saves no notebook: a preview is
//      read-only, and its bytes hold one student's values;
//   5. Starter swaps back: the placeholder, editable, no task header;
//   6. after a swap to Solution, Save & validate saves the solution, not the
//      starter that the page first loaded.
//
// SMOKE_SCREENSHOT_DIR, when set, receives a screenshot after each step.
//
// Usage:   node workbench-preview-check.mjs <baseURL>
// Exit 0 = healthy; exit 1 = broken (details printed).

import { chromium, webkit, firefox } from "playwright";
import fs from "node:fs";
import path from "node:path";
import { registerStudent, seedInstructorAssignment } from "./seed.mjs";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
const STEP_MS = 30_000;
const shots = process.env.SMOKE_SCREENSHOT_DIR;

function fail(reason) {
  console.log(`PREVIEW FAIL — ${reason}`);
  process.exit(1);
}

const NOTEBOOK = {
  nbformat: 4,
  nbformat_minor: 5,
  metadata: { kernelspec: { name: "xpython", display_name: "Python (xeus-python)", language: "python" } },
  cells: [
    { cell_type: "markdown", id: "h1", source: ["## Task 1: Greet\n"], metadata: {} },
    { cell_type: "code", id: "greet", metadata: {}, outputs: [], execution_count: null, source: ["word = \"{{greeting}}\"\n"] },
  ],
};

const MANIFEST = {
  schemaVersion: 1,
  gradingMode: "browser",
  language: "python",
  requiredFiles: [],
  sections: [{ id: "s1", name: "Task 1: Greet", variables: [] }],
  testSuites: [{ tier: "public", script: "test_greet.py", sectionID: "s1", points: 1 }],
  globalVariables: [{ name: "greeting", value: "bonjour" }],
  timeLimitSeconds: 10,
  makefile: null,
};

const FILES = { "test_greet.py": "assert word == 'bonjour'\n" };

async function main() {
  console.log(`Browser engine: ${browserName}`);
  let seeded;
  let username;
  try {
    seeded = await seedInstructorAssignment(baseURL, {
      notebook: NOTEBOOK, files: FILES, manifest: MANIFEST, title: "Preview Lab",
    });
    username = await registerStudent(baseURL);
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
  const saves = [];
  page.on("request", (r) => { if (r.url().includes("/notebook/save")) saves.push(r.url()); });
  context.on("page", (p) => p.close().catch(() => {}));
  const finish = async (exitCode) => { await browser.close(); process.exit(exitCode); };
  let step = 0;
  const shot = async (name) => {
    if (!shots) return;
    fs.mkdirSync(shots, { recursive: true });
    step += 1;
    await page.screenshot({ path: path.join(shots, `${String(step).padStart(2, "0")}-${browserName}-${name}.png`) });
  };
  const idleCount = () => page.evaluate(() => window.__ck.filter((d) => d.ck === "ck:kernel" && d.status === "idle").length);
  const waitFor = async (label, predicate, timeout = STEP_MS) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (await predicate()) return;
      await page.waitForTimeout(250);
    }
    throw new Error(`timed out: ${label}`);
  };
  const editor = () => page.frameLocator("#jl-frame");
  const editorText = () => editor().locator(".jp-Notebook").innerText().catch(() => "");
  const readOnly = () => page.locator("#jl-frame").getAttribute("data-read-only");
  const summary = page.locator(".js-wb-preview-menu > summary .wb-preview-label");

  try {
    await page.goto(`${baseURL}/instructor/${seeded.assignmentID}/workbench?file=assignment&view=template`, {
      waitUntil: "domcontentloaded",
    });
    await waitFor("first kernel idle", async () => (await idleCount()) > 0, KERNEL_BOOT_MS);
    await waitFor("the template", async () => (await editorText()).includes("{{greeting}}"));

    // (1) The menu lists the student.
    await summary.click();
    const item = page.locator(".wb-preview-panel .row-menu-item", { hasText: username });
    if ((await item.count()) !== 1) return fail(`the menu does not list ${username}`);
    await shot("menu");

    // (2) Picking the student swaps in their starter, read-only.
    const before = await idleCount();
    await item.click();
    await waitFor("the preview kernel idle", async () => (await idleCount()) > before, KERNEL_BOOT_MS);
    await waitFor("the student's value", async () => (await editorText()).includes("bonjour"));
    if ((await editorText()).includes("{{greeting}}")) return fail("the preview still shows the placeholder");
    if ((await readOnly()) !== "true") return fail("the preview is not read-only");
    if (!page.url().includes("&as=")) return fail(`the address does not name the preview: ${page.url()}`);
    const label = (await summary.textContent()) || "";
    if (label !== `Preview: ${username}`) return fail(`the menu button says "${label}"`);

    // (3) The student's task header, and no test cards.
    await waitFor("the task header", async () => (await editor().locator(".ck-task-header").count()) > 0);
    const header = (await editor().locator(".ck-task-header").first().innerText()).replace(/\s+/g, " ");
    console.log(`preview header: ${header}`);
    // No attempt: an unchanged task is "Still the starter code", an edited
    // one "Not submitted yet". Neither names an attempt.
    if (!/Still the starter code|Not submitted yet/.test(header) || /attempt/i.test(header)) {
      return fail(`the header says "${header}"`);
    }
    if ((await editor().locator(".ck-card").count()) !== 0) return fail("the preview shows test cards");
    await shot("preview");

    // (4) Save & validate in the preview saves no notebook.
    await page.locator("#wb-save").click();
    await waitFor("the save to finish", async () => !(await page.locator("#wb-save").isDisabled()));
    if (saves.length) return fail(`a preview saved its notebook: ${saves.join(", ")}`);

    // (5) Starter swaps back.
    const beforeBack = await idleCount();
    await page.locator('.wb-view[data-wb-target-file="assignment"]:not([data-wb-target-view])').click();
    await waitFor("the starter kernel idle", async () => (await idleCount()) > beforeBack, KERNEL_BOOT_MS);
    await waitFor("the template again", async () => (await editorText()).includes("{{greeting}}"));
    if ((await readOnly()) !== "false") return fail("the starter is read-only after the preview");
    if (((await summary.textContent()) || "") !== "Preview as student") return fail("the menu button still names the student");
    await waitFor("no task header", async () => (await editor().locator(".ck-task-header").count()) === 0);
    await shot("back");

    // (6) After a swap to Solution, the save names the solution.
    const beforeSolution = await idleCount();
    await page.locator('.wb-view[data-wb-target-file="solution"]').click();
    await waitFor("the solution kernel idle", async () => (await idleCount()) > beforeSolution, KERNEL_BOOT_MS);
    await page.locator("#wb-save").click();
    await waitFor("a notebook save", async () => saves.length > 0);
    console.log(`save after the swap: ${saves[0].replace(baseURL, "")}`);
    if (!/[?&]file=solution(&|$)/.test(saves[0])) return fail(`the save after a swap to Solution was ${saves[0]}`);

    console.log("PREVIEW OK");
    await finish(0);
  } catch (e) {
    console.log(`PREVIEW FAIL — ${(e && e.message) || e}`);
    await shot("failure").catch(() => {});
    await finish(1);
  }
}

main();
