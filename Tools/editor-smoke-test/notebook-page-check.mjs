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
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
// Generous: the real page boots TWO Pyodides (editor kernel + grader). Without
// the JupyterLite service worker's asset cache (disabled now that the kernel
// syncs over SharedArrayBuffer) that double load is heavier — measurably so
// under WebKit — so grading-to-result can take a few minutes on a cold runner.
const SUBMIT_RESULT_MS = parseInt(process.env.SMOKE_SUBMIT_MS || "240000", 10);

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
  // Escape hatch for running this locally against a pre-installed browser whose
  // build number does not match the pinned Playwright's expectation. CI installs
  // the matching build and leaves this unset.
  if (process.env.SMOKE_BROWSER_PATH) {
    launchOptions.executablePath = process.env.SMOKE_BROWSER_PATH;
  }
  const browser = await browserType.launch(launchOptions);
  const context = await browser.newContext({ storageState: seeded.storageState });
  // Capture the in-iframe kernel-boot collector's breadcrumbs on the PARENT
  // window (the collector posts to window.parent, which IS the notebook page
  // here). Installed in every frame before any page script. Lets us assert the
  // funnel advances past boot_start in the REAL notebooks editor — the surface
  // editor-check.mjs (the REPL) can't exercise because the REPL has no
  // window.jupyterapp for the collector's status detection.
  await context.addInitScript(() => {
    try {
      window.__ckKernelDiag = window.__ckKernelDiag || [];
      window.addEventListener("message", (e) => {
        const d = e && e.data;
        if (d && d.ck === "kernel-diag") {
          window.__ckKernelDiag.push({ kind: d.kind, source: d.source, message: d.message });
        }
      });
    } catch (_) { /* ignore */ }
  });
  const page = await context.newPage();

  // Stray-tab guard. Notebook 7 opens each document in its own browser tab via
  // window.open; embedded in our iframe that surfaces as a redundant second
  // editor tab (a third Pyodide). With the fix — parent-side window.open
  // suppression (notebook.js) + the server self-close page
  // (JupyterLiteAppIndexMiddleware) — no such tab should ever open, so ANY new
  // page in this context after the main one is a regression. Record + close it
  // (so a stray second editor can't keep running and skew timings).
  const strayTabs = [];
  context.on("page", (p) => {
    strayTabs.push(p.url());
    p.close().catch(() => {});
  });

  const blocked = [];
  page.on("requestfailed", (req) => {
    const why = req.failure()?.errorText || "";
    if (/ERR_BLOCKED|BlockedByResponse/i.test(why)) blocked.push(`${req.url()} — ${why}`);
  });

  // Capture the grading submit-phase breadcrumbs the page POSTs to
  // /api/v1/client-diagnostics (sent with keepalive, so they reach us even when
  // the grading worker is wedged). On a grading hang these localize WHERE it
  // stalled — the only window into an otherwise invisible worker-thread hang:
  //   grading_init_start without grading_init_done  → stuck in worker init
  //   pyodide_loaded without env_configured          → stuck after Pyodide load
  //   grading_init_done without suite_done           → stuck in a test run
  // See Public/browser-runner.js GradingWorkerExecutor + Public/grading-worker.js.
  const gradingPhases = [];
  page.on("request", (req) => {
    try {
      if (req.method() !== "POST" || !/\/api\/v1\/client-diagnostics/.test(req.url())) return;
      const body = req.postData();
      if (!body) return;
      const j = JSON.parse(body);
      if (j && (j.kind === "submit_phase" || j.kind === "submit_error")) {
        gradingPhases.push(`${j.source}${j.message ? " [" + j.message + "]" : ""}`);
      }
    } catch (_) { /* best-effort telemetry */ }
  });
  const phaseTrail = () => `grading breadcrumbs: ${gradingPhases.join(" -> ") || "(none captured)"}`;

  const finish = async (code) => { await browser.close(); process.exit(code); };

  try {
    await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });

    // The page redirects unauthenticated/unenrolled users to /login — guard that
    // the seed actually produced an authorized student on the real page.
    if (/\/login/.test(page.url())) return fail(`redirected to login — student not authorized (url=${page.url()})`);

    // (1) Cross-origin isolation is now ENGINE-DEPENDENT. Chromium/Blink/Gecko
    // get the isolated SharedArrayBuffer path; WebKit gets the NON-isolated
    // comlink + service-worker path, because the SAB/`coincident` handshake
    // deadlocks the kernel on WebKit (see EditorEngineDetection.swift). Assert
    // the page is in the state its engine expects — both directions, so a
    // silent isolation flip on either engine is caught.
    const expectIsolated = browserName !== "webkit";
    const isolated = await page.evaluate(() => globalThis.crossOriginIsolated === true);
    console.log(`crossOriginIsolated = ${isolated} (expected ${expectIsolated} for ${browserName})`);
    if (expectIsolated && !isolated) {
      return fail("the real notebook page is NOT cross-origin isolated (COEP missing on /testsetups/:id/notebook)");
    }
    if (!expectIsolated && isolated) {
      return fail("the WebKit notebook page IS cross-origin isolated — it must be served non-isolated so the kernel uses the comlink transport");
    }

    // (2) Our app Web Workers must spawn from the real isolated page (the #986
    // regression: a require-corp page can't spawn a worker whose script lacks
    // COEP). We do NOT spawn a synthetic probe worker here — that would start a
    // second Pyodide load (grading-worker.js importScripts pyodide at startup)
    // and contend with the real grading. Instead the page exercises the workers
    // for us: notebook.js spawns /freeze-watchdog-worker.js on load and
    // browser-runner.js spawns /grading-worker.js on Submit. A COEP block of
    // either surfaces as an ERR_BLOCKED request, captured in `blocked` and
    // asserted below (and the Submit step would also fail). Editor-check.mjs
    // keeps the active probe for the standalone case.

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

    // (3b) Kernel-boot collector: in the REAL notebooks editor the collector
    // must actually advance past boot_start to kernel_idle. This both validates
    // the kernelBootFunnel end-to-end (the gap editor-check.mjs leaves) AND
    // proves the collector's poll loop terminates — if its status detection
    // failed here it would never set done=true and would poll for the full 75s
    // boot deadline, wasted main-thread work on every editor open. Probe the
    // iframe's own ServiceManager too, so a failure says WHICH side broke.
    const idleDeadline = Date.now() + 60_000;
    let sawIdle = false;
    while (Date.now() < idleDeadline) {
      const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
      if (diag.some((d) => d.kind === "kernel_phase" && d.source === "kernel_idle")) { sawIdle = true; break; }
      await page.waitForTimeout(1000);
    }
    if (!sawIdle) {
      const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
      let smProbe = "(probe failed)";
      try {
        smProbe = await jlFrame.evaluate(() => {
          const app = window.jupyterapp;
          const sm = app && app.serviceManager;
          const out = { hasJupyterapp: typeof app, hasServiceManager: !!sm };
          // Hunt for the real kernel-status signal in the DOM.
          out.dataStatus = Array.from(document.querySelectorAll("[data-status]"))
            .map((el) => ({ tag: el.tagName, cls: el.className, status: el.getAttribute("data-status") }))
            .slice(0, 10);
          out.statusish = Array.from(document.querySelectorAll("*"))
            .filter((el) => typeof el.className === "string" &&
              /(ernelStatus|ExecutionIndicator|jp-KernelName|StatusBar)/.test(el.className))
            .map((el) => ({ cls: el.className, title: el.getAttribute("title"), text: (el.textContent || "").slice(0, 40) }))
            .slice(0, 12);
          out.bodyTail = ((document.body && document.body.textContent) || "").replace(/\s+/g, " ").slice(-200);
          return out;
        }).then(JSON.stringify);
      } catch { /* ignore */ }
      return fail(
        "the kernel-boot collector never reported kernel_idle in the real notebooks editor — " +
          "its status detection does not match this app's ServiceManager, so the funnel is stuck at " +
          "boot_start AND the collector polls the full boot deadline. " +
          `Captured=${JSON.stringify(diag)} iframeServiceManager=${smProbe}`
      );
    }
    console.log("kernel-boot collector: funnel reached kernel_idle in the real notebooks editor");

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
    // Wait for the grader to render a terminal result line ("N / M passed …").
    const gotResults = await page.waitForFunction(
      () => {
        const el = document.getElementById("nb-results");
        if (!el || el.hidden) return false;
        return /\d+\s*\/\s*\d+\s*passed/i.test(el.innerText || "");
      },
      null, { timeout: SUBMIT_RESULT_MS }
    ).then(() => true).catch(() => false);
    if (blocked.length) return fail("blocked resources during submit/grading (a worker was COEP-blocked)", blocked.join("\n"));
    if (!gotResults) return fail(`no grading result rendered within ${SUBMIT_RESULT_MS}ms`, phaseTrail());
    const resultText = (await results.innerText()).replace(/\s+/g, " ").trim().slice(0, 200);
    console.log(`grading result rendered: "${resultText}"`);
    // The fixture's one public test (`print(...)`, exit 0) must PASS — a
    // result of "1 / 1 passed" proves grading-worker.js spawned under isolation,
    // loaded Pyodide, ran the test, and posted a correct outcome end-to-end.
    if (!/1\s*\/\s*1\s*passed/i.test(resultText)) {
      return fail(`grading did not pass cleanly (expected "1 / 1 passed"): ${resultText}`);
    }

    if (strayTabs.length) {
      return fail(
        `${strayTabs.length} stray editor tab(s) opened — Notebook 7's window.open was not suppressed: ${strayTabs.join(", ")}`
      );
    }

    console.log(`E2E PASS — real notebook page isolated, workers spawned, kernel booted, submit graded 1/1 (engine=${browserName})`);
    console.log(phaseTrail());
    await finish(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`, blocked.length ? blocked.join("\n") : undefined);
  }
}

main();
