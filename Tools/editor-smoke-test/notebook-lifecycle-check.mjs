// notebook-lifecycle-check.mjs
//
// Headless END-TO-END check of the notebook EDITOR lifecycle on the real student
// page (`/testsetups/:id/notebook`) — the surfaces the required editor-smoke
// gate does NOT cover (it proves boot + a Submit grade only). Built to confirm
// the JupyterLite 0.8 / Pyodide 314 upgrade keeps the in-editor working-copy
// flows healthy, since 0.8 changed the ContentsManager / Drive wiring.
//
// Flow (one student, one fresh browser context so IndexedDB persists across the
// reloads):
//
//   1. Boot the editor; the seeded starter cell (marker CKSTARTER) renders from
//      the Drive and the kernel reaches idle.
//   2. SAVE round-trip: append a unique marker (CKSAVE_<stamp>) to cell 0 via the
//      notebook model and run `docmanager:save`, then RELOAD the same context and
//      assert the marker survived — i.e. the editor persisted the edit to the
//      IndexedDB Drive and the reseed logic kept the local copy (the v0.4.154
//      "don't wipe in-progress work" contract) on 0.8.
//   3. RESET: POST the student self-reset (`/testsetups/:id/reset-notebook`,
//      which overwrites the server working copy with the starter), RELOAD, and
//      assert the editor reseeded — the save marker is gone and CKSTARTER is back
//      (the server-newer reseed branch on 0.8).
//
// Seeds through the real HTTP API exactly like editor-exec-check.mjs / the
// notebook-page check (instructor -> course -> browser test setup -> student).
//
// Usage:  node notebook-lifecycle-check.mjs <baseURL>
// Env:    SMOKE_BROWSER (chromium|webkit|firefox), SMOKE_KERNEL_MS.
// Exit 0 = lifecycle healthy; exit 1 = a step failed (details printed).

import { chromium, webkit, firefox } from "playwright";
import { request as pwRequest } from "playwright";
import JSZip from "jszip";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");

const PAGE_LOAD_MS = 30_000;
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
const IDLE_WAIT_MS = 90_000;

const STAMP = Date.now().toString(36);
const STARTER_MARKER = "CKSTARTER";
const SAVE_MARKER = `CKSAVE_${STAMP}`;
const STARTER_SOURCE = `# ${STARTER_MARKER}\nx = 1\n`;

const INSTRUCTOR = { username: `lc_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `lc_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `LC${STAMP}`.slice(0, 12), name: "Lifecycle Course" };

const MANIFEST = JSON.stringify({
  schemaVersion: 1,
  gradingMode: "browser",
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }],
  timeLimitSeconds: 10,
  makefile: null,
});

function fail(reason, extra) {
  console.log(`LIFECYCLE FAIL — ${reason}`);
  if (extra) console.log(extra);
  process.exit(1);
}

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
        { cell_type: "code", source: [STARTER_SOURCE], metadata: {}, outputs: [], execution_count: null },
      ],
    })
  );
  zip.file("test_public.py", 'print("public test ok")\n');
  return zip.generateAsync({ type: "nodebuffer" });
}

// Seed via the real HTTP API (mirrors editor-exec-check.mjs).
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

// Find the live JupyterLite editor iframe.
async function findEditorFrame(page) {
  for (let i = 0; i < 60; i++) {
    const fr = page.frames().find((f) => /\/jupyterlite\//.test(f.url()));
    if (fr) return fr;
    await page.waitForTimeout(500);
  }
  return null;
}

// Wait until the editor shell is up AND the cell source containing `mustContain`
// has rendered from the Drive.
async function waitForEditorWithSource(jlFrame, mustContain) {
  return await jlFrame.waitForFunction(
    (needle) => {
      const jp = document.querySelectorAll("[class^='jp-'],[class*=' jp-']").length;
      const text = (document.body && document.body.innerText) || "";
      return jp > 20 && text.includes(needle);
    },
    mustContain,
    { timeout: KERNEL_BOOT_MS }
  ).then(() => true).catch(() => false);
}

// Wait for the kernel-boot collector to report idle (bridged to the parent page).
async function waitForKernelIdle(page) {
  const deadline = Date.now() + IDLE_WAIT_MS;
  while (Date.now() < deadline) {
    const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
    if (diag.some((d) => d.kind === "kernel_phase" && d.source === "kernel_idle")) return true;
    await page.waitForTimeout(500);
  }
  return false;
}

// Append a marker comment to cell 0 via the notebook model, then save to the
// Drive. Returns "ok" or a diagnostic string. Tolerant of the JupyterLab 4 /
// Notebook 7 shared-model API shape JupyterLite 0.8 ships.
async function appendToCellAndSave(jlFrame, marker) {
  return await jlFrame.evaluate(async (mk) => {
    const app = window.jupyterapp;
    if (!app || !app.shell) return "no jupyterapp/shell";
    function panelFrom(w) { return w && w.content && w.content.model ? w : null; }
    let panel = panelFrom(app.shell.currentWidget);
    if (!panel) {
      try {
        const it = app.shell.widgets ? app.shell.widgets("main") : null;
        if (it) { let r; while (!(r = it.next()).done) { const p = panelFrom(r.value); if (p) { panel = p; break; } } }
      } catch (_) { /* ignore */ }
    }
    if (!panel) return "no notebook panel";
    const model = panel.content.model;
    if (!model || !model.cells || model.cells.length === 0) return "no cells in model";
    const cell = model.cells.get(0);
    const sm = cell.sharedModel || cell;
    let cur = "";
    try { cur = typeof sm.getSource === "function" ? sm.getSource() : (sm.source || ""); } catch (_) { cur = ""; }
    const next = `${cur}\n# ${mk}\n`;
    try {
      if (typeof sm.setSource === "function") sm.setSource(next);
      else if ("source" in sm) sm.source = next;
      else return "no setSource/source on shared model";
    } catch (e) { return "setSource threw: " + (e && e.message ? e.message : e); }
    try {
      await app.commands.execute("docmanager:save");
    } catch (e) { return "docmanager:save threw: " + (e && e.message ? e.message : e); }
    return "ok";
  }, marker);
}

async function bodyText(jlFrame) {
  return await jlFrame.evaluate(() => (document.body && document.body.innerText) || "").catch(() => "");
}

async function main() {
  console.log(`Browser engine: ${browserName}`);
  console.log(`Seeding browser-graded assignment via ${baseURL} …`);
  let seeded;
  try { seeded = await seed(); }
  catch (e) { return fail(`seeding failed: ${(e && e.message) || e}`); }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`Seeded setup ${seeded.setupID}; driving editor lifecycle on ${notebookURL}`);

  const launchOptions =
    browserName === "chromium"
      ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
      : { headless: true };
  const browser = await browserType.launch(launchOptions);
  // ONE context for the whole run so the IndexedDB Drive persists across reloads.
  const context = await browser.newContext({ storageState: seeded.storageState });
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
  const finish = async (code) => { await browser.close(); process.exit(code); };

  try {
    // ---- Step 1: boot, render starter, kernel idle -----------------------
    await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    if (/\/login/.test(page.url())) return fail(`redirected to login — student not authorized (url=${page.url()})`);
    let jlFrame = await findEditorFrame(page);
    if (!jlFrame) return fail("the JupyterLite editor iframe never attached");
    if (!(await waitForEditorWithSource(jlFrame, STARTER_MARKER))) {
      return fail("editor never rendered the seeded starter cell", (await bodyText(jlFrame)).slice(0, 300));
    }
    if (!(await waitForKernelIdle(page))) return fail("kernel never reported idle");
    console.log("step 1 ok: editor booted, starter rendered, kernel idle");

    // ---- Step 2: edit + save, then reload and assert it persisted --------
    const editResult = await appendToCellAndSave(jlFrame, SAVE_MARKER);
    if (editResult !== "ok") return fail(`could not edit + save the notebook: ${editResult}`);
    // Give the Drive write a moment to flush before reloading.
    await page.waitForTimeout(2000);
    console.log("step 2: edited cell 0 and ran docmanager:save; reloading…");

    await page.reload({ waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    jlFrame = await findEditorFrame(page);
    if (!jlFrame) return fail("editor iframe never re-attached after save+reload");
    if (!(await waitForEditorWithSource(jlFrame, STARTER_MARKER))) {
      return fail("editor did not re-render the notebook after save+reload", (await bodyText(jlFrame)).slice(0, 300));
    }
    // The saved edit must survive the reload (IndexedDB Drive + keep-local reseed).
    const afterSave = await jlFrame.waitForFunction(
      (needle) => ((document.body && document.body.innerText) || "").includes(needle),
      SAVE_MARKER, { timeout: 30_000 }
    ).then(() => true).catch(() => false);
    if (!afterSave) {
      return fail(
        "saved edit did NOT survive reload — the editor reseeded over in-progress work " +
          "(0.8 ContentsManager/Drive save or keep-local reseed regressed)",
        (await bodyText(jlFrame)).slice(0, 300)
      );
    }
    console.log("step 2 ok: saved edit persisted across reload");

    // ---- Step 3: reset, then reload and assert it reverted ---------------
    let csrf;
    try {
      const html = await (await page.request.get(`${baseURL}/`)).text();
      csrf = extractCsrf(html);
    } catch (_) { /* fall through */ }
    if (!csrf) return fail("could not obtain a CSRF token to POST the reset");
    const resetRes = await page.request.post(`${baseURL}/testsetups/${seeded.setupID}/reset-notebook`, {
      form: { _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    });
    if (![200, 302, 303].includes(resetRes.status())) {
      return fail(`reset-notebook POST failed: status ${resetRes.status()}`, (await resetRes.text()).slice(0, 300));
    }
    console.log("step 3: posted reset-notebook; reloading…");

    await page.reload({ waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    jlFrame = await findEditorFrame(page);
    if (!jlFrame) return fail("editor iframe never re-attached after reset+reload");
    if (!(await waitForEditorWithSource(jlFrame, STARTER_MARKER))) {
      return fail("editor did not re-render the starter after reset+reload", (await bodyText(jlFrame)).slice(0, 300));
    }
    // After reset the working copy is the starter again, so the editor must
    // reseed and the save marker must be GONE. Poll briefly to let the
    // server-newer reseed settle.
    let reverted = false;
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const text = await bodyText(jlFrame);
      if (text.includes(STARTER_MARKER) && !text.includes(SAVE_MARKER)) { reverted = true; break; }
      await page.waitForTimeout(1000);
    }
    if (!reverted) {
      return fail(
        "reset did NOT revert the working copy — the save marker is still present after reset+reload " +
          "(0.8 reset / server-newer reseed regressed)",
        (await bodyText(jlFrame)).slice(0, 300)
      );
    }
    console.log("step 3 ok: reset reverted the notebook to the starter");

    console.log(`LIFECYCLE PASS — save round-trip + reset verified on the real notebook editor (engine=${browserName})`);
    await finish(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`);
  }
}

main();
