// editor-exec-check.mjs
//
// CI REPRODUCER for the production post-idle kernel execution hang (`exec_hang`).
// In production ~1 in 5 real-notebook sessions reach `kernel_idle` (the editor
// boots fine) and THEN wedge on the first cell execute — the cell sits `[*]`
// busy forever (45s+; a kernel restart does not clear it). The boot funnel and
// the existing notebook-page smoke both go blind to this: notebook-page-check.mjs
// proves the editor BOOTS and that browser GRADING runs, but it never executes
// an EDITOR cell, and editor-check.mjs only drives the standalone REPL (a single
// Pyodide, no iframe), which executes fine in CI. The student bug lives on the
// real page — the editor kernel running a cell beside the grading/freeze workers.
//
// This probe closes that gap: open the REAL student notebook page, wait for
// kernel_idle, then run the seeded editor cell and assert its stdout appears.
//
// It runs TWO arms to localise the cause (and answer "can type-checking stay?"):
//   • immediate — run the cell the instant kernel_idle fires (delay 0), which
//     maximally RACES the post-idle nb_mypy background load (asyncio.ensure_future
//     in scripts/patch-pyodide-kernel.py → loadPackage(mypy WASM) + a per-cell
//     pre_run_cell mypy hook). This is the worst case and should reproduce.
//   • settled — wait EXEC_SETTLE_MS after idle (let that background load finish)
//     before running. If the hang DISAPPEARS when settled, the cause is the
//     load-vs-execute race and nb_mypy can be DEFERRED rather than dropped; if it
//     still hangs, the synchronous per-cell mypy run itself is the cost.
//
// Looping each arm measures the hang RATE; on a hang it captures the in-iframe
// kernel-diag breadcrumbs (incl. exec_hang), the execution-indicator data-status,
// console errors, and any unhandledrejection text, so a hung run is diagnostic.
//
// DIAGNOSTIC harness — run via the `editor-exec-probe` workflow, deliberately NOT
// wired into the required editor-smoke gate while we hunt the root cause, so an
// intermittent hang can't flake the merge gate. Seeds through the real HTTP API
// exactly like notebook-page-check.mjs (instructor → course → browser test setup
// → student), then drives the page with the student's session.
//
// Usage:  node editor-exec-check.mjs <baseURL>
// Env:    SMOKE_BROWSER (chromium|webkit|firefox), EXEC_ITER (cycles per arm,
//         default 5), EXEC_BUDGET_MS (per-cell execute budget, default 60000 —
//         > the 45s exec_hang threshold so a real hang also trips the beacon),
//         EXEC_SETTLE_MS (settle wait for the "settled" arm, default 45000).
// Exit 0 = the immediate arm saw no hangs (bug gone); exit 1 = it reproduced (or
// a setup failure). The settled arm is reported but does not set the exit code.

import { chromium, webkit, firefox } from "playwright";
import { request as pwRequest } from "playwright";
import JSZip from "jszip";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");

const ITER = Math.max(1, parseInt(process.env.EXEC_ITER || "5", 10));
const EXEC_BUDGET_MS = parseInt(process.env.EXEC_BUDGET_MS || "60000", 10);
const EXEC_SETTLE_MS = parseInt(process.env.EXEC_SETTLE_MS || "45000", 10);
const PAGE_LOAD_MS = 30_000;
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
const IDLE_WAIT_MS = 90_000;

// The seeded cell prints a distinctive token so "did the cell run?" is an
// unambiguous substring check. The SOURCE carries "CKEXEC=%d" (used to confirm
// the editor rendered the cell from the Drive); only the OUTPUT is "CKEXEC=42",
// so polling for the latter detects execution, never the source.
const EXEC_TOKEN = "CKEXEC=42";
const NB_CELL_SOURCE = 'print("CKEXEC=%d" % (6 * 7))\n';

const STAMP = Date.now().toString(36);
const INSTRUCTOR = { username: `xq_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `xq_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `XQ${STAMP}`.slice(0, 12), name: "Exec Probe Course" };

const MANIFEST = JSON.stringify({
  schemaVersion: 1,
  gradingMode: "browser",
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }],
  timeLimitSeconds: 10,
  makefile: null,
});

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

async function expectOK(label, resPromise, okStatuses) {
  const res = await resPromise;
  if (!okStatuses.includes(res.status())) {
    let body = "";
    try { body = (await res.text()).slice(0, 400); } catch { /* ignore */ }
    throw new Error(`${label}: unexpected status ${res.status()} (wanted ${okStatuses.join("/")})\n${body}`);
  }
  return res;
}

async function buildSetupZip() {
  const zip = new JSZip();
  zip.file(
    "assignment.ipynb",
    JSON.stringify({
      nbformat: 4,
      nbformat_minor: 5,
      metadata: { kernelspec: { name: "python", display_name: "Python" } },
      cells: [
        { cell_type: "code", source: [NB_CELL_SOURCE], metadata: {}, outputs: [], execution_count: null },
      ],
    })
  );
  zip.file("test_public.py", 'print("public test ok")\n');
  return zip.generateAsync({ type: "nodebuffer" });
}

// Seed via the real HTTP API (mirrors notebook-page-check.mjs): the first
// registered user becomes admin, creates a course, flips it to auto-enroll,
// uploads a browser-graded setup, then a student registers + logs in (which
// auto-enrolls). Returns the setup id + the student's storage state.
async function seed() {
  const instr = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(instr, "/register");
  await expectOK("register instructor",
    instr.post("/register", { form: { username: INSTRUCTOR.username, password: INSTRUCTOR.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);

  csrf = await csrfFrom(instr, "/admin/courses/new");
  const courseRes = await expectOK("create course",
    instr.post("/admin/courses", { form: { code: COURSE.code, name: COURSE.name, _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
    [302, 303]);
  const loc = courseRes.headers()["location"] || "";
  const courseID = (loc.match(/\/admin\/courses\/([0-9a-fA-F-]{36})/) || [])[1];
  if (!courseID) throw new Error(`could not parse courseID from redirect: "${loc}"`);
  await expectOK("set enrollment auto",
    instr.post(`/courses/${courseID}/enrollment-mode`, { form: { enrollmentMode: "auto", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
    [302, 303]);

  const zipBuf = await buildSetupZip();
  csrf = await csrfFrom(instr, "/");
  const setupRes = await expectOK("upload test setup",
    instr.post("/api/v1/testsetups", {
      multipart: { manifest: MANIFEST, courseID, files: { name: "setup.zip", mimeType: "application/zip", buffer: zipBuf } },
      headers: { "x-csrf-token": csrf },
    }),
    [200, 201]);
  const setupID = JSON.parse(await setupRes.text()).testSetupID;
  if (!setupID) throw new Error("no testSetupID in upload response");
  await instr.dispose();

  const stud = await pwRequest.newContext({ baseURL });
  csrf = await csrfFrom(stud, "/register");
  await expectOK("register student",
    stud.post("/register", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  csrf = await csrfFrom(stud, "/login");
  await expectOK("login student",
    stud.post("/login", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  const storageState = await stud.storageState();
  await stud.dispose();

  return { setupID, storageState };
}

// One open→idle→(wait delayMs)→execute cycle in a fresh context (fresh kernel +
// SAB + IndexedDB). Returns { hung, ms, status, note, diag, errors, rej }.
async function probeOnce(browser, storageState, notebookURL, delayMs) {
  const context = await browser.newContext({ storageState });
  // Capture the in-iframe collector's breadcrumbs AND any unhandledrejection
  // text on the parent (the notebook page) — same bridge the production
  // telemetry uses. The rejection text is best-effort: a kernel-worker rejection
  // may not reach the iframe window, but page console still surfaces its type.
  await context.addInitScript(() => {
    try {
      window.__ckKernelDiag = [];
      window.__ckRej = [];
      window.addEventListener("message", (e) => {
        const d = e && e.data;
        if (d && d.ck === "kernel-diag") window.__ckKernelDiag.push({ kind: d.kind, source: d.source, message: d.message });
      });
      window.addEventListener("unhandledrejection", (e) => {
        try {
          const r = e && e.reason;
          window.__ckRej.push(String((r && (r.message || r.stack)) || r || "rejection").slice(0, 1200));
        } catch (_) { /* ignore */ }
      });
    } catch (_) { /* ignore */ }
  });
  const page = await context.newPage();
  const errors = [];
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text().slice(0, 800)); });
  page.on("pageerror", (e) => errors.push(((e && (e.stack || e.message)) || String(e)).slice(0, 800)));

  const result = { hung: true, ms: 0, status: null, note: "", diag: [], errors, rej: [] };
  const readDiag = () => page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
  try {
    await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    if (/\/login/.test(page.url())) { result.note = "redirected to login (student not authorized)"; return result; }

    // Editor iframe attaches and renders the seeded cell from the Drive.
    let jlFrame = null;
    for (let k = 0; k < 60 && !jlFrame; k++) {
      jlFrame = page.frames().find((fr) => /\/jupyterlite\//.test(fr.url()));
      if (!jlFrame) await page.waitForTimeout(500);
    }
    if (!jlFrame) { result.note = "editor iframe never attached"; return result; }
    const loaded = await jlFrame.waitForFunction(() => {
      const jp = document.querySelectorAll("[class^='jp-'],[class*=' jp-']").length;
      const text = (document.body && document.body.innerText) || "";
      return jp > 20 && /CKEXEC/.test(text);
    }, null, { timeout: KERNEL_BOOT_MS }).then(() => true).catch(() => false);
    if (!loaded) { result.note = "editor never rendered the seeded cell"; return result; }

    // Wait for kernel_idle (the collector breadcrumb), then wait delayMs, then run.
    const idleDeadline = Date.now() + IDLE_WAIT_MS;
    let sawIdle = false;
    while (Date.now() < idleDeadline) {
      const diag = await readDiag();
      if (diag.some((d) => d.kind === "kernel_phase" && d.source === "kernel_idle")) { sawIdle = true; break; }
      await page.waitForTimeout(500);
    }
    if (!sawIdle) { result.note = "kernel never reported idle"; result.diag = await readDiag(); return result; }

    if (delayMs > 0) await page.waitForTimeout(delayMs);

    // Run the first code cell in the NOTEBOOK editor (Shift+Enter is the run
    // binding). This is the path the REPL smoke can't exercise.
    const cell = jlFrame.locator(".jp-Notebook .jp-CodeCell .cm-content").first();
    await cell.click({ timeout: 15_000 });
    await cell.press("Shift+Enter");

    // Wait for the cell's stdout token to render in the editor iframe.
    const start = Date.now();
    let ran = false;
    while (Date.now() - start < EXEC_BUDGET_MS) {
      const body = await jlFrame.evaluate(() => (document.body && document.body.innerText) || "").catch(() => "");
      if (body.includes(EXEC_TOKEN)) { ran = true; break; }
      await page.waitForTimeout(500);
    }
    result.ms = Date.now() - start;
    result.hung = !ran;
    result.status = await jlFrame.evaluate(() => {
      const ind = document.querySelector(".jp-Notebook-ExecutionIndicator[data-status]");
      return ind ? ind.getAttribute("data-status") : null;
    }).catch(() => null);
    result.diag = await readDiag();
    result.rej = await page.evaluate(() => window.__ckRej || []).catch(() => []);
  } catch (e) {
    result.note = `exception: ${(e && e.message) || e}`;
  } finally {
    await context.close().catch(() => {});
  }
  return result;
}

// Run one arm of `n` cycles at a fixed post-idle delay; returns { hangs, lat }.
async function runArm(label, delayMs, browser, storageState, notebookURL, n) {
  let hangs = 0;
  const lat = [];
  for (let i = 0; i < n; i++) {
    const r = await probeOnce(browser, storageState, notebookURL, delayMs);
    if (r.hung) {
      hangs++;
      const exec = (r.diag || []).find((d) => d.source === "exec_hang");
      console.log(
        `  [${label}] ${i + 1}/${n}: HANG${r.note ? " (" + r.note + ")" : ""} — ` +
          `indicator=${r.status} waited=${r.ms}ms exec_hang=${exec ? exec.message : "none"}`
      );
      if (r.rej && r.rej.length) console.log(`      rejection: ${r.rej[0]}`);
      else if (r.errors && r.errors.length) console.log(`      console: ${r.errors.slice(0, 3).join(" | ")}`);
    } else {
      lat.push(r.ms);
      console.log(`  [${label}] ${i + 1}/${n}: ok — ran in ${r.ms}ms (indicator=${r.status})`);
    }
  }
  const avg = lat.length ? Math.round(lat.reduce((a, b) => a + b, 0) / lat.length) : 0;
  console.log(`  [${label}] arm result — hangs=${hangs}/${n} ok=${n - hangs} avgRunMs=${avg}`);
  return { hangs, avg };
}

async function main() {
  console.log(`Browser engine: ${browserName}; iterations/arm=${ITER}; budget=${EXEC_BUDGET_MS}ms; settle=${EXEC_SETTLE_MS}ms`);
  let seeded;
  try { seeded = await seed(); }
  catch (e) { console.log(`EXEC PROBE SETUP FAIL — ${(e && e.message) || e}`); process.exit(1); }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`Seeded setup ${seeded.setupID}; probing ${notebookURL}`);

  const launchOptions =
    browserName === "chromium"
      ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
      : { headless: true };
  const browser = await browserType.launch(launchOptions);

  // Arm A: run the instant the kernel idles — maximally races the nb_mypy load.
  console.log(`--- arm: immediate (delay 0 — races the post-idle background load) ---`);
  const immediate = await runArm("immediate", 0, browser, seeded.storageState, notebookURL, ITER);
  // Arm B: wait for that background load to finish before running.
  console.log(`--- arm: settled (delay ${EXEC_SETTLE_MS}ms — background load has finished) ---`);
  const settled = await runArm("settled", EXEC_SETTLE_MS, browser, seeded.storageState, notebookURL, ITER);

  await browser.close();

  console.log(
    `EXEC PROBE RESULT — engine=${browserName} ` +
      `immediate=${immediate.hangs}/${ITER} hangs (avgOk=${immediate.avg}ms) | ` +
      `settled=${settled.hangs}/${ITER} hangs (avgOk=${settled.avg}ms)`
  );
  // Exit code keyed on the immediate arm: red while it reproduces, green when a
  // fix (drop/defer nb_mypy) makes it stop hanging.
  process.exit(immediate.hangs > 0 ? 1 : 0);
}

main();
