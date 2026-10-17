// notebook-graded-check.mjs — the graded toast in the real editor (notebook
// views NB5, frame 18f), on the browser-graded path.
//
// Seeds a browser-graded Python assignment, opens the real student page, and
// asserts:
//
//   1. Submit grades in the browser, and the toast says "Attempt 1 graded",
//      100% and "1 of 1 check passed.", with the stars and the hop;
//   2. the guide updates in place: the outline's attempt card and the task
//      pill say attempt 1, the inline results panel stays hidden, and the
//      editor does not reload or restart its kernel;
//   3. Keep editing closes the toast;
//   4. a failing second attempt shows no stars and "0 of 1 check passed.";
//   5. with reduced motion the bird does not hop.
//
// The worker-graded path needs a native runner, which this harness does not
// start; Tests/BrowserRunnerJSTests/notebook-graded.test.mjs covers its poll.
//
// SMOKE_SCREENSHOT_DIR, when set, receives a screenshot after each step.
//
// Usage:   node notebook-graded-check.mjs <baseURL>
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
const GRADE_MS = parseInt(process.env.SMOKE_SUBMIT_RESULT_MS || "240000", 10);
const STEP_MS = 30_000;
const shots = process.env.SMOKE_SCREENSHOT_DIR;

function fail(reason) {
  console.log(`GRADED FAIL — ${reason}`);
  process.exit(1);
}

const NOTEBOOK = {
  nbformat: 4,
  nbformat_minor: 5,
  metadata: { kernelspec: { name: "xpython", display_name: "Python (xeus-python)", language: "python" } },
  cells: [
    { cell_type: "markdown", id: "h1", source: ["## Task 1: Count\n"], metadata: {} },
    {
      cell_type: "code", id: "count", metadata: {}, outputs: [], execution_count: null,
      source: ["def count_to(n):\n", "    return list(range(n))\n"],
    },
  ],
};

const MANIFEST = {
  schemaVersion: 1,
  gradingMode: "browser",
  language: "python",
  requiredFiles: [],
  sections: [{ id: "s1", name: "Task 1: Count", variables: [] }],
  testSuites: [{ tier: "public", script: "test_count.py", sectionID: "s1", points: 1 }],
  timeLimitSeconds: 10,
  makefile: null,
};

// The runner names the student's module in .chickadee_student_module.
const FILES = {
  "test_count.py": [
    "import importlib.util",
    "path = open('.chickadee_student_module').read().strip()",
    "spec = importlib.util.spec_from_file_location('student', path)",
    "student = importlib.util.module_from_spec(spec)",
    "spec.loader.exec_module(student)",
    "assert student.count_to(3) == [0, 1, 2]",
    "",
  ].join("\n"),
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

  const toast = page.locator("#nb-graded");
  const pills = () => editor().locator(".ck-task-header .ck-pill").allTextContents();
  const submit = async () => {
    await page.waitForFunction(() => { const b = document.getElementById("nb-submit"); return b && !b.disabled; }, null, { timeout: STEP_MS });
    await page.locator("#nb-submit").click();
  };
  const toastSays = async () => ({
    caption: await toast.locator(".js-nb-graded-caption").textContent(),
    grade: await toast.locator(".js-nb-graded-grade").textContent(),
    summary: await toast.locator(".js-nb-graded-summary").textContent(),
    perfect: await toast.evaluate((el) => el.classList.contains("is-perfect")),
  });

  try {
    await page.goto(`${baseURL}/testsetups/${seeded.setupID}/notebook`, { waitUntil: "domcontentloaded" });
    if (/\/login/.test(page.url())) return fail("redirected to login");
    await waitFor("ck:kernel idle", async () => (await events("ck:kernel")).some((d) => d.status === "idle"), KERNEL_BOOT_MS);
    await waitFor("the task header", async () => (await pills()).length === 1);
    // A mark in the editor document: a reload of the editor would lose it.
    await editorFrame().evaluate(() => { window.__ckSameDocument = true; });
    const startsBefore = (await events("ck:kernel")).filter((d) => d.status === "starting").length;

    // (1) A passing attempt. The starter already passes, so an edit first:
    // an unchanged cell reads "Still the starter code" whatever the grade.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "count_to" }));
    await editor().locator(".jp-CodeCell").first().locator(".cm-content").click();
    await page.keyboard.press("Control+End");
    await page.keyboard.type("\n# my version");
    await waitFor("the edit is seen", async () => (await pills())[0] === "Not submitted yet");
    await submit();
    await toast.waitFor({ state: "visible", timeout: GRADE_MS });
    const first = await toastSays();
    console.log(`toast 1: ${JSON.stringify(first)}`);
    if (first.caption !== "Attempt 1 graded" || first.grade !== "100%" || first.summary !== "1 of 1 check passed.") {
      return fail(`toast 1 says ${JSON.stringify(first)}`);
    }
    if (!first.perfect) return fail("toast 1 has no stars at 100%");
    if (!(await toast.locator(".nb-graded-star").first().isVisible())) return fail("the stars are not visible at 100%");
    const hop = await toast.locator(".avatar").evaluate((el) => getComputedStyle(el).animationName);
    if (hop !== "bird-hop") return fail(`the bird does not hop at 100%: ${hop}`);
    await shot("perfect");

    // (2) In place.
    await waitFor("the pill says attempt 1", async () => (await pills())[0] === "Passed in attempt 1");
    const card = await page.locator("#nb-outline .outline-attempt").textContent();
    if (!card.includes("Attempt 1")) return fail(`the attempt card says ${card}`);
    if (!(await page.locator("#nb-results").isHidden())) return fail("the inline results panel shows beside the toast");
    if (!(await editorFrame().evaluate(() => window.__ckSameDocument === true))) return fail("the editor reloaded");
    const startsAfter = (await events("ck:kernel")).filter((d) => d.status === "starting").length;
    if (startsAfter !== startsBefore) return fail("the kernel restarted");
    if (!(await page.locator("#nb-graded-results").getAttribute("href")).startsWith("/submissions/")) {
      return fail("See results does not link to the submission");
    }

    // (3) Keep editing.
    await page.locator("#nb-graded-close").click();
    if (await toast.isVisible()) return fail("Keep editing did not close the toast");

    // (4) A failing attempt.
    await page.evaluate(() => window.chickadeeEditorCommand("chickadee:reveal", { name: "count_to" }));
    await editor().locator(".jp-CodeCell").first().locator(".cm-content").click();
    await page.keyboard.press("Control+a");
    await page.keyboard.type("def count_to(n):\n    return []");
    await submit();
    await waitFor("toast 2", async () => (await toast.isVisible()) && (await toastSays()).caption === "Attempt 2 graded", GRADE_MS);
    const second = await toastSays();
    console.log(`toast 2: ${JSON.stringify(second)}`);
    if (second.summary !== "0 of 1 check passed." || second.perfect) return fail(`toast 2 says ${JSON.stringify(second)}`);
    if (await toast.locator(".nb-graded-star").first().isVisible()) return fail("stars show below 100%");
    await waitFor("the pill says attempt 2", async () => (await pills())[0] === "1 check failed in attempt 2");
    await shot("failed");

    // (5) Reduced motion: no hop, even at 100%.
    await page.emulateMedia({ reducedMotion: "reduce" });
    await toast.evaluate((el) => el.classList.add("is-perfect"));
    const still = await toast.locator(".avatar").evaluate((el) => getComputedStyle(el).animationName);
    if (still !== "none") return fail(`the bird hops under reduced motion: ${still}`);

    console.log("GRADED OK");
    return finish(0);
  } catch (e) {
    await shot("failure").catch(() => {});
    console.log(`GRADED FAIL — ${(e && e.message) || e}`);
    return finish(1);
  }
}

main();
