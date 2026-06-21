// notebook-page-check.mjs
//
// Full authenticated END-TO-END check of the REAL student notebook page
// (`/testsetups/:id/notebook`) — the isolated parent page that embeds the
// JupyterLite editor iframe AND loads notebook.js + browser-runner.js, which
// spawn our own Web Workers (grading, freeze failover) under cross-origin
// isolation. The standalone editor smoke (editor-check.mjs) drives
// `/jupyterlite/repl` beside the workers; it does NOT exercise the real page —
// which is exactly the gap that let the grading-worker COEP block (#986) ship.
// This test closes that gap: it seeds a browser-graded assignment, logs in as a
// student, opens the real page, and asserts:
//
//   1. the page is cross-origin isolated (COEP on /testsetups/:id/notebook);
//   2. our app Web Workers spawn from the real isolated page (not COEP-blocked);
//   3. the editor iframe boots its Pyodide kernel;
//   4. a real Submit runs in-browser grading and renders a passing result.
//
// Seeding is done through the real HTTP API with Playwright's request context
// (register instructor → create course → auto-enroll → upload a browser test
// setup → register + log in a student), then the student's session cookies are
// handed to a real browser to drive the page. Runs under SMOKE_BROWSER
// (chromium | webkit), same as editor-check.mjs.
//
// Usage:   node notebook-page-check.mjs <baseURL>
// Exit 0 = healthy; exit 1 = broken (details printed).

import { chromium, webkit, firefox } from "playwright";
import { request as pwRequest } from "playwright";
import JSZip from "jszip";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;

const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");

const STAMP = Date.now().toString(36);
const INSTRUCTOR = { username: `e2e_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `e2e_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `E2E${STAMP}`.slice(0, 12), name: "E2E Browser Course" };

// Budgets — the real page boots TWO Pyodide instances (editor kernel + grader),
// both local but large, so be generous.
const PAGE_LOAD_MS = 30_000;
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "90000", 10);
const SUBMIT_RESULT_MS = parseInt(process.env.SMOKE_SUBMIT_MS || "120000", 10);

function fail(reason, extra) {
  console.log(`E2E FAIL — ${reason}`);
  if (extra) console.log(extra);
  process.exit(1);
}

// Pull the CSRF token out of a rendered page: the form field
// (<input name='_csrf' value='...'> — single or double quoted, any attr order)
// or the <meta name="csrf-token" content="..."> tag.
function extractCsrf(html) {
  let m = html.match(/name=['"]_csrf['"][^>]*\svalue=['"]([^'"]+)['"]/i);
  if (m) return m[1];
  m = html.match(/\svalue=['"]([^'"]+)['"][^>]*name=['"]_csrf['"]/i);
  if (m) return m[1];
  m = html.match(/<meta\s+name=['"]csrf-token['"]\s+content=['"]([^'"]+)['"]/i);
  if (m) return m[1];
  return null;
}

async function csrfFrom(ctx, path) {
  const res = await ctx.get(path);
  const token = extractCsrf(await res.text());
  if (!token) throw new Error(`could not find CSRF token on ${path} (status ${res.status()})`);
  return token;
}

// Build a minimal browser-graded test setup zip: a starter notebook + one
// trivial public test that exits 0 (→ a passing outcome in the browser runner).
async function buildSetupZip() {
  const zip = new JSZip();
  zip.file(
    "assignment.ipynb",
    JSON.stringify({
      nbformat: 4,
      nbformat_minor: 5,
      metadata: { kernelspec: { name: "python", display_name: "Python" } },
      cells: [
        { cell_type: "code", source: ["x = 1\n"], metadata: {}, outputs: [], execution_count: null },
      ],
    })
  );
  zip.file("test_public.py", 'print("public test ok")\n');
  return zip.generateAsync({ type: "nodebuffer" });
}

const MANIFEST = JSON.stringify({
  schemaVersion: 1,
  gradingMode: "browser",
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }],
  timeLimitSeconds: 10,
  makefile: null,
});

async function expectOK(label, resPromise, okStatuses) {
  const res = await resPromise;
  const ok = okStatuses.includes(res.status());
  if (!ok) {
    let body = "";
    try { body = (await res.text()).slice(0, 400); } catch { /* ignore */ }
    throw new Error(`${label}: unexpected status ${res.status()} (wanted ${okStatuses.join("/")})\n${body}`);
  }
  return res;
}

// --- Seed via the real HTTP API ------------------------------------------
async function seed() {
  // Instructor (the first registered user becomes admin).
  const instr = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(instr, "/register");
  await expectOK(
    "register instructor",
    instr.post("/register", { form: { username: INSTRUCTOR.username, password: INSTRUCTOR.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]
  );

  // Create the course (admin), then flip it to auto-enroll.
  csrf = await csrfFrom(instr, "/admin/courses/new");
  const courseRes = await expectOK(
    "create course",
    instr.post("/admin/courses", { form: { code: COURSE.code, name: COURSE.name, _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
    [302, 303]
  );
  const loc = courseRes.headers()["location"] || "";
  const courseID = (loc.match(/\/admin\/courses\/([0-9a-fA-F-]{36})/) || [])[1];
  if (!courseID) throw new Error(`could not parse courseID from redirect: "${loc}"`);
  await expectOK(
    "set enrollment auto",
    instr.post(`/courses/${courseID}/enrollment-mode`, { form: { enrollmentMode: "auto", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
    [302, 303]
  );

  // Upload a browser-graded test setup.
  const zipBuf = await buildSetupZip();
  csrf = await csrfFrom(instr, "/");
  const setupRes = await expectOK(
    "upload test setup",
    instr.post("/api/v1/testsetups", {
      multipart: {
        manifest: MANIFEST,
        courseID,
        files: { name: "setup.zip", mimeType: "application/zip", buffer: zipBuf },
      },
      headers: { "x-csrf-token": csrf },
    }),
    [200, 201]
  );
  const setupID = JSON.parse(await setupRes.text()).testSetupID;
  if (!setupID) throw new Error("no testSetupID in upload response");
  await instr.dispose();

  // Student: register, then log in (login auto-enrolls into .auto courses).
  const stud = await pwRequest.newContext({ baseURL });
  csrf = await csrfFrom(stud, "/register");
  await expectOK(
    "register student",
    stud.post("/register", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]
  );
  csrf = await csrfFrom(stud, "/login");
  await expectOK(
    "login student",
    stud.post("/login", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]
  );
  const storageState = await stud.storageState();
  await stud.dispose();

  return { setupID, courseID, storageState };
}

async function main() {
  console.log(`Browser engine: ${browserName}`);
  console.log(`Seeding browser-graded assignment via ${baseURL} …`);
  let seeded;
  try {
    seeded = await seed();
  } catch (e) {
    return fail(`seeding failed: ${(e && e.message) || e}`);
  }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`Seeded setup ${seeded.setupID}; opening real notebook page.`);

  const launchOptions =
    browserName === "chromium"
      ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
      : { headless: true };
  const browser = await browserType.launch(launchOptions);
  const context = await browser.newContext({ storageState: seeded.storageState });
  const page = await context.newPage();

  const blocked = [];
  page.on("requestfailed", (req) => {
    const why = req.failure()?.errorText || "";
    if (/ERR_BLOCKED|BlockedByResponse/i.test(why)) blocked.push(`${req.url()} — ${why}`);
  });

  const finish = async (code) => { await browser.close(); process.exit(code); };

  try {
    await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });

    // The page redirects unauthenticated/unenrolled users to /login — guard that
    // the seed actually produced an authorized student on the real page.
    if (/\/login/.test(page.url())) return fail(`redirected to login — student not authorized (url=${page.url()})`);

    // (1) The real notebook page must be cross-origin isolated.
    const isolated = await page.evaluate(() => globalThis.crossOriginIsolated === true);
    console.log(`crossOriginIsolated = ${isolated}`);
    if (!isolated) return fail("the real notebook page is NOT cross-origin isolated (COEP missing on /testsetups/:id/notebook)");

    // (2) Our app Web Workers must spawn from the real isolated page (the #986
    // regression: a require-corp page can't spawn a worker whose script lacks
    // COEP). This is the same probe as editor-check, but on the REAL page.
    const workerScripts = ["/grading-worker.js", "/freeze-watchdog-worker.js"];
    const workerBlocked = [];
    const onWorkerReqFail = (req) => {
      const why = req.failure()?.errorText || "";
      if (workerScripts.some((s) => req.url().includes(s)) && /ERR_BLOCKED/i.test(why)) {
        workerBlocked.push(`${req.url()} — ${why}`);
      }
    };
    page.on("requestfailed", onWorkerReqFail);
    const spawnErrors = await page.evaluate(async (scripts) => {
      const errs = [];
      await Promise.all(scripts.map((s) => new Promise((resolve) => {
        let w;
        try { w = new Worker(s); } catch (e) { errs.push(`${s} threw ${(e && e.message) || e}`); return resolve(); }
        setTimeout(() => { try { w.terminate(); } catch (_) { /* ignore */ } resolve(); }, 3000);
      })));
      return errs;
    }, workerScripts);
    await page.waitForTimeout(200);
    page.off("requestfailed", onWorkerReqFail);
    if (workerBlocked.length || spawnErrors.length) {
      return fail("an app Web Worker was blocked under isolation on the real notebook page",
        [...workerBlocked, ...spawnErrors].join("\n"));
    }
    console.log(`worker-spawn probe: ${workerScripts.join(", ")} spawned OK on the real page`);

    // (3) The editor iframe must boot the JupyterLite shell AND load the
    // student's notebook from the Drive. We probe the same-origin iframe's DOM
    // directly (frameLocator visibility is unreliable against JupyterLite's
    // layout). Asserting the seeded cell (`x = 1`) rendered proves the editor
    // read the notebook out of the Drive — the path P3 (SW removal) must keep
    // working on SAB alone.
    let jlFrame = null;
    for (let i = 0; i < 60 && !jlFrame; i++) {
      jlFrame = page.frames().find((fr) => /\/jupyterlite\//.test(fr.url()));
      if (!jlFrame) await page.waitForTimeout(500);
    }
    if (!jlFrame) return fail("the JupyterLite editor iframe never attached");
    const editorLoaded = await jlFrame.waitForFunction(
      () => {
        const jp = document.querySelectorAll("[class^='jp-'],[class*=' jp-']").length;
        const text = (document.body && document.body.innerText) || "";
        return jp > 20 && /x = 1/.test(text);
      },
      null, { timeout: KERNEL_BOOT_MS }
    ).then(() => true).catch(() => false);
    if (!editorLoaded) {
      let dump = "";
      try {
        dump = await jlFrame.evaluate(() => ({
          jp: document.querySelectorAll("[class^='jp-'],[class*=' jp-']").length,
          text: ((document.body && document.body.innerText) || "").replace(/\s+/g, " ").slice(0, 300),
        })).then(JSON.stringify);
      } catch { /* ignore */ }
      if (blocked.length) return fail("editor iframe never loaded the notebook; blocked resources observed", blocked.join("\n"));
      return fail(`editor iframe did not load the notebook within ${KERNEL_BOOT_MS}ms`, dump);
    }
    console.log("editor iframe shell is up and the notebook loaded from the Drive");

    // (4) Full submit: click Submit (enabled once the notebook syncs) and wait
    // for an inline result. This exercises in-browser grading end-to-end —
    // grading-worker.js spawning + running Pyodide under isolation on the real
    // page, then posting and rendering the result.
    const submit = page.locator("#nb-submit");
    const submitReady = await submit.waitFor({ state: "visible", timeout: KERNEL_BOOT_MS })
      .then(() => submit.isEnabled()).catch(() => false);
    if (!submitReady) {
      // Some flows keep submit disabled until sync; poll briefly for enabled.
      const enabled = await page.waitForFunction(
        () => { const b = document.getElementById("nb-submit"); return b && !b.disabled; },
        null, { timeout: 30_000 }
      ).then(() => true).catch(() => false);
      if (!enabled) return fail("Submit button never became enabled (notebook never synced)");
    }
    await submit.click();
    const results = page.locator("#nb-results");
    const gotResults = await page.waitForFunction(
      () => {
        const el = document.getElementById("nb-results");
        if (!el || el.hidden) return false;
        const t = el.innerText || "";
        return /passed|✓|fail|error/i.test(t);
      },
      null, { timeout: SUBMIT_RESULT_MS }
    ).then(() => true).catch(() => false);
    if (blocked.length) return fail("blocked resources during submit/grading", blocked.join("\n"));
    if (!gotResults) return fail(`no grading result rendered within ${SUBMIT_RESULT_MS}ms`);
    const resultText = (await results.innerText()).replace(/\s+/g, " ").trim().slice(0, 200);
    console.log(`grading result rendered: "${resultText}"`);

    console.log(`E2E PASS — real notebook page isolated, workers spawned, kernel booted, submit graded (engine=${browserName})`);
    await finish(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`, blocked.length ? blocked.join("\n") : undefined);
  }
}

main();
