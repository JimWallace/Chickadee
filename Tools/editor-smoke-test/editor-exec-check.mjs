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
// kernel_idle, then IMMEDIATELY run the seeded editor cell (maximising the race
// against the post-idle nb_mypy background load) and assert its stdout appears.
// Looping (EXEC_ITER) measures the hang RATE; on a hang it captures the in-iframe
// kernel-diag breadcrumbs (including `exec_hang`), the execution-indicator
// data-status, and console errors, so a hung run is diagnostic rather than a
// black box.
//
// THREE failure classes, classified and counted separately:
//   - deadlock      — our-code post-idle exec_hang (the bug this probe hunts);
//                     FAILS the leg (exit 1).
//   - webkitWasmCrash — the upstream WebKit/Safari WASM engine crash
//                     ("Out of bounds memory access" in __pyproxy_apply, WebKit
//                     bug #286266). NOT a Chickadee regression and not fixable in
//                     our JS; reported but does NOT fail the leg, so WebKit's own
//                     bug can't flake this diagnostic.
//   - lostDispatch  — the first Shift+Enter never started the cell (indicator
//                     stays idle, no busy phase, no exec_hang beacon) but a
//                     SECOND press runs it promptly: the kernel was healthy and
//                     the keypress was lost (focus race around the post-idle
//                     window). A different bug class than the sustained-busy
//                     hang — reported loudly but does NOT fail the leg, so the
//                     deadlock signal stays clean (2026-07-02 chromium repro:
//                     hangs=1/8 with indicator=idle exec_hang=none).
// Each iteration uses a FRESH browser: one WebKit process accumulates WASM /
// TextDecoder state across back-to-back kernel boots, inflating the WebKit crash
// rate well above a real student (one kernel per session). Fresh-per-run makes the
// measured rate a true single-session figure — production telemetry corroborates
// that real Safari students rarely hit it.
//
// DIAGNOSTIC harness — run via the `editor-exec-probe` workflow, deliberately NOT
// wired into the required editor-smoke gate while we hunt the root cause, so an
// intermittent hang can't flake the merge gate. Seeds through the real HTTP API
// exactly like notebook-page-check.mjs (instructor → course → browser test setup
// → student), then drives the page with the student's session.
//
// Usage:  node editor-exec-check.mjs <baseURL>
// Env:    SMOKE_BROWSER (chromium|webkit|firefox), EXEC_ITER (default 1),
//         EXEC_BUDGET_MS (default 60000 — > the 45s exec_hang threshold so a real
//         hang also trips the in-iframe exec_hang beacon), EXEC_DELAY_MS (default
//         0 — ms to wait after kernel_idle before running, to vary the race).
// Exit 0 = no hangs observed; exit 1 = at least one hang (or a setup failure).

import { chromium, webkit, firefox } from "playwright";
import { request as pwRequest } from "playwright";
import JSZip from "jszip";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");

const ITER = Math.max(1, parseInt(process.env.EXEC_ITER || "1", 10));
const EXEC_BUDGET_MS = parseInt(process.env.EXEC_BUDGET_MS || "60000", 10);
const EXEC_DELAY_MS = parseInt(process.env.EXEC_DELAY_MS || "0", 10);
const PAGE_LOAD_MS = 30_000;
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
const IDLE_WAIT_MS = 90_000;

// The seeded cell prints a distinctive token so "did the cell run?" is an
// unambiguous substring check. The SOURCE carries "CKEXEC=%d" (used to confirm
// the editor rendered the cell from the Drive); only the OUTPUT is "CKEXEC=42",
// so polling for the latter detects execution, never the source.
const EXEC_TOKEN = "CKEXEC=42";
const NB_CELL_SOURCE = 'print("CKEXEC=%d" % (6 * 7))\n';

// The fatal upstream WebKit/Safari WASM crash (WebKit bug #286266): Pyodide's
// kernel dies mid-execute with "RuntimeError: Out of bounds memory access
// (evaluating '__pyproxy_apply(...)')" (and the sibling "RangeError: Bad value").
// It's a Safari WASM-engine defect, NOT a Chickadee regression and NOT fixable in
// our JS — zero non-WebKit occurrences are reported upstream. We classify a hang
// caused by it separately from a real (our-code) post-idle deadlock so the probe
// stays honest: a pure-WebKit-crash run is reported but does NOT fail the leg.
const WASM_CRASH_RE = /out of bounds memory access|Pyodide has suffered a fatal error|__pyproxy_apply|RangeError: Bad value/i;

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

// One open→idle→execute cycle in a fresh context (fresh kernel + SAB + IndexedDB).
// Returns { hung, ms, status, note, diag, errors }.
async function probeOnce(browser, storageState, notebookURL) {
  const context = await browser.newContext({ storageState });
  // Capture the in-iframe collector's breadcrumbs on the parent (the notebook
  // page), same bridge the production telemetry uses.
  await context.addInitScript(() => {
    try {
      window.__ckKernelDiag = [];
      window.addEventListener("message", (e) => {
        const d = e && e.data;
        if (d && d.ck === "kernel-diag") window.__ckKernelDiag.push({ kind: d.kind, source: d.source, message: d.message });
      });
    } catch (_) { /* ignore */ }
  });
  const page = await context.newPage();
  const errors = [];
  // Console "Failed to load resource" messages don't carry the URL in their
  // text (the 2026-07-02 chromium hang printed four bare 403s — evidence
  // wasted); attach the location URL so a failing resource is identifiable.
  page.on("console", (m) => {
    if (m.type() !== "error") return;
    const loc = m.location();
    const url = loc && loc.url ? ` [${loc.url}]` : "";
    errors.push((m.text() + url).slice(0, 300));
  });
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  // Network-level forensics, independent of what the console reports: every
  // >=400 response and every outright-failed request, for ALL iterations —
  // printing them only on hangs made ambient 4xx noise look hang-correlated.
  const badResponses = [];
  page.on("response", (res) => {
    if (res.status() >= 400) {
      badResponses.push(`${res.status()} ${res.request().method()} ${res.url()}`.slice(0, 220));
    }
  });
  page.on("requestfailed", (req) => {
    const why = (req.failure() && req.failure().errorText) || "";
    badResponses.push(`FAIL ${req.method()} ${req.url()} ${why}`.slice(0, 220));
  });

  const result = {
    hung: true, wasmCrash: false, lostDispatch: false, dialogStole: false,
    dialogText: "", ms: 0, status: null,
    note: "", diag: [], errors, badResponses, cellState: "",
  };
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

    // Wait for kernel_idle (the collector breadcrumb), then run immediately.
    const idleDeadline = Date.now() + IDLE_WAIT_MS;
    let sawIdle = false;
    while (Date.now() < idleDeadline) {
      const diag = await readDiag();
      if (diag.some((d) => d.kind === "kernel_phase" && d.source === "kernel_idle")) { sawIdle = true; break; }
      await page.waitForTimeout(500);
    }
    if (!sawIdle) { result.note = "kernel never reported idle"; result.diag = await readDiag(); return result; }

    if (EXEC_DELAY_MS > 0) await page.waitForTimeout(EXEC_DELAY_MS);

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
      // Bail early on the upstream WebKit WASM crash rather than waiting out the
      // full budget — the kernel is dead, the token will never appear.
      if ((result.errors || []).some((e) => WASM_CRASH_RE.test(e))) { result.wasmCrash = true; break; }
      await page.waitForTimeout(500);
    }
    result.ms = Date.now() - start;
    result.hung = !ran;
    if (!result.wasmCrash) result.wasmCrash = (result.errors || []).some((e) => WASM_CRASH_RE.test(e));
    result.status = await jlFrame.evaluate(() => {
      const ind = document.querySelector(".jp-Notebook-ExecutionIndicator[data-status]");
      return ind ? ind.getAttribute("data-status") : null;
    }).catch(() => null);
    result.diag = await readDiag();

    if (result.hung && !result.wasmCrash) {
      // Cell + focus state at the moment the budget expired: prompt "[*]"
      // means the execute was dispatched and is stuck (the sustained-busy
      // class); "[ ]" with an idle indicator means it was never dispatched.
      result.cellState = await jlFrame.evaluate(() => {
        const cell = document.querySelector(".jp-Notebook .jp-CodeCell");
        const prompt = cell ? ((cell.querySelector(".jp-InputPrompt") || {}).textContent || "").trim() : "no-cell";
        const out = cell ? ((cell.querySelector(".jp-OutputArea") || {}).innerText || "").trim().slice(0, 60) : "";
        const activeEl = document.activeElement;
        const active = activeEl ? String(activeEl.className || activeEl.tagName).slice(0, 60) : "none";
        return `prompt="${prompt}" docFocus=${document.hasFocus()} active="${active}" out="${out}"`;
      }).catch(() => "unavailable");

      // A modal JupyterLab dialog (`.jp-Dialog`) intercepts keyboard focus, so
      // Shift+Enter never reaches the cell — the cell prompt stays "[ ]" and the
      // active element is a `jp-Dialog-button` (observed 2026-07-02 chromium:
      // the folder-creation 403s / insertWidget error surface an error dialog).
      // This is a distinct, student-facing bug ("I pressed run and nothing
      // happened") from a wedged kernel; capture WHICH dialog and dismiss it so
      // the second-press discriminator can confirm the kernel underneath is
      // healthy.
      result.dialogText = await jlFrame.evaluate(() => {
        const dialog = document.querySelector(".jp-Dialog");
        if (!dialog) return "";
        const header = (dialog.querySelector(".jp-Dialog-header") || {}).textContent || "";
        const body = (dialog.querySelector(".jp-Dialog-body") || {}).textContent || "";
        return (header + " | " + body).trim().slice(0, 200);
      }).catch(() => "");
      if (result.dialogText) {
        // Dismiss the dialog (Escape, then reject-button fallback) before the
        // retry so the keypress can reach the cell.
        await jlFrame.evaluate(() => {
          const btn = document.querySelector(".jp-Dialog-button.jp-mod-reject")
            || document.querySelector(".jp-Dialog-button");
          if (btn) btn.click();
        }).catch(() => {});
        await page.keyboard.press("Escape").catch(() => {});
        await page.waitForTimeout(500);
      }

      // Discriminator: lost keypress / dialog-steal vs wedged kernel. If a
      // second Shift+Enter (after any dialog is dismissed) runs the cell
      // promptly, the kernel was healthy the whole time and the FIRST dispatch
      // never landed — a focus problem, not a deadlock.
      try {
        const cellAgain = jlFrame.locator(".jp-Notebook .jp-CodeCell .cm-content").first();
        await cellAgain.click({ timeout: 5_000 });
        await cellAgain.press("Shift+Enter");
        const retryStart = Date.now();
        while (Date.now() - retryStart < 15_000) {
          const body = await jlFrame.evaluate(() => (document.body && document.body.innerText) || "").catch(() => "");
          if (body.includes(EXEC_TOKEN)) {
            if (result.dialogText) result.dialogStole = true;
            else result.lostDispatch = true;
            break;
          }
          await page.waitForTimeout(500);
        }
      } catch { /* second press unavailable — leave classification as deadlock */ }
    }
  } catch (e) {
    result.note = `exception: ${(e && e.message) || e}`;
  } finally {
    await context.close().catch(() => {});
  }
  return result;
}

async function main() {
  console.log(`Browser engine: ${browserName}; iterations=${ITER}; budget=${EXEC_BUDGET_MS}ms; delay=${EXEC_DELAY_MS}ms`);
  let seeded;
  try { seeded = await seed(); }
  catch (e) { console.log(`EXEC PROBE SETUP FAIL — ${(e && e.message) || e}`); process.exit(1); }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`Seeded setup ${seeded.setupID}; probing ${notebookURL}`);

  const launchOptions =
    browserName === "chromium"
      ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
      : { headless: true };

  let hangs = 0;
  let wasmCrashes = 0;
  let deadlocks = 0;
  let lostDispatches = 0;
  let dialogSteals = 0;
  const latencies = [];
  for (let i = 0; i < ITER; i++) {
    // Fresh browser per iteration. A single WebKit process accumulates WASM /
    // TextDecoder state across back-to-back Pyodide boots, which inflates the
    // upstream WebKit crash rate far above a real student's one-kernel-per-
    // session experience. Relaunching isolates each run so the measured rate
    // reflects a single session (chromium is unaffected either way).
    const browser = await browserType.launch(launchOptions);
    let r;
    try { r = await probeOnce(browser, seeded.storageState, notebookURL); }
    finally { await browser.close().catch(() => {}); }
    if (r.hung) {
      hangs++;
      if (r.wasmCrash) wasmCrashes++;
      else if (r.dialogStole) dialogSteals++;
      else if (r.lostDispatch) lostDispatches++;
      else deadlocks++;
      const exec = (r.diag || []).find((d) => d.source === "exec_hang");
      const tag = r.wasmCrash
        ? "WEBKIT-WASM-CRASH (upstream #286266)"
        : r.dialogStole
          ? "DIALOG-STEAL (modal dialog swallowed the keypress; cell ran after dismiss)"
          : r.lostDispatch
            ? "LOST-DISPATCH (second press ran — kernel healthy, first keypress lost)"
            : "HANG";
      console.log(
        `  iter ${i + 1}/${ITER}: ${tag}${r.note ? " (" + r.note + ")" : ""} — ` +
          `indicator=${r.status} waited=${r.ms}ms exec_hang=${exec ? exec.message : "none"}`
      );
      if (r.cellState) console.log(`    cell: ${r.cellState}`);
      if (r.dialogText) console.log(`    dialog: ${r.dialogText}`);
      if (r.errors && r.errors.length) console.log(`    console: ${r.errors.slice(0, 4).join(" | ")}`);
      if (r.badResponses && r.badResponses.length) {
        console.log(`    http: ${r.badResponses.slice(0, 6).join(" | ")}`);
      }
    } else {
      latencies.push(r.ms);
      // Compact per-iteration noise summary even on green runs: without the
      // base rate, ambient 4xx noise printed only on hangs looks correlated.
      console.log(
        `  iter ${i + 1}/${ITER}: ok — ran in ${r.ms}ms ` +
          `(indicator=${r.status}, net4xx=${(r.badResponses || []).length}, consoleErr=${(r.errors || []).length})`
      );
    }
    // Identify the ambient noise once per run (it is constant per engine:
    // chromium 11x4xx/6err, webkit 4x4xx/6err on 2026-07-02): the deduped
    // URL set turns "net4xx=11" from a count into a diagnosis.
    if (i === 0) {
      const uniqueBad = [...new Set(r.badResponses || [])];
      const uniqueErr = [...new Set(r.errors || [])];
      if (uniqueBad.length) console.log(`  ambient http (iter 1): ${uniqueBad.join(" | ")}`);
      if (uniqueErr.length) console.log(`  ambient console (iter 1): ${uniqueErr.join(" | ")}`);
    }
  }

  const avg = latencies.length ? Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length) : 0;
  console.log(
    `EXEC PROBE RESULT — engine=${browserName} hangs=${hangs}/${ITER} ` +
      `(deadlock=${deadlocks}, dialogSteal=${dialogSteals}, lostDispatch=${lostDispatches}, ` +
      `webkitWasmCrash=${wasmCrashes}) ok=${ITER - hangs} avgRunMs=${avg}`
  );
  if (dialogSteals > 0) {
    console.log(
      `NOTE: ${dialogSteals}/${ITER} run(s) had a modal dialog swallow the first Shift+Enter ` +
        `(the cell ran after the dialog was dismissed — kernel healthy). Student-facing: an ` +
        `error/confirm dialog over the editor makes the first run do nothing. See the per-iter ` +
        `"dialog:" line for which dialog; likely tied to the folder-creation 403s / insertWidget error.`
    );
  }
  if (lostDispatches > 0) {
    console.log(
      `NOTE: ${lostDispatches}/${ITER} run(s) lost the first Shift+Enter (a second press ran fine — ` +
        `kernel healthy). This is a post-idle focus race, not the sustained-busy exec_hang; it is ` +
        `student-facing ("I pressed run and nothing happened") and tracked separately so the ` +
        `deadlock signal stays clean.`
    );
  }
  if (wasmCrashes > 0) {
    console.log(
      `NOTE: ${wasmCrashes}/${ITER} run(s) hit the upstream WebKit/Safari WASM crash ` +
        `(WebKit bug #286266: "Out of bounds memory access" in __pyproxy_apply) — not a Chickadee ` +
        `regression, not fixable in our JS. Fresh-browser-per-run, so this is the true single-session rate.`
    );
  }
  // Fail the leg ONLY for a real (our-code) post-idle deadlock; an upstream
  // WebKit WASM crash or a lost first keypress (kernel healthy, different bug
  // class) is reported but must not flake this diagnostic.
  process.exit(deadlocks > 0 ? 1 : 0);
}

main();
