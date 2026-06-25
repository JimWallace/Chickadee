// notebook-bridge-check.mjs
//
// Headless probe for the jupyter-iframe-commands command bridge — the
// supported replacement for notebook.js's fragile
// `frame.contentWindow.jupyterapp.commands.execute(...)` cross-frame poking.
//
// Two halves make the bridge:
//   * the `jupyter-iframe-commands` labextension, federated into the JupyterLite
//     0.8 bundle (Tools/jupyterlite/requirements.txt) — runs INSIDE the editor
//     iframe, auto-starts, and `expose`s the JupyterLab command registry over
//     comlink/postMessage, signalling `_JUPYTER_IFRAME_COMMANDS_LOADED`;
//   * the `jupyter-iframe-commands-host` bridge, vendored to
//     /vendor/iframe-commands-host.js — runs in the PARENT frame and wraps the
//     iframe's comlink endpoint.
//
// This probe proves the bridge end-to-end AND that notebook.js's production
// save path (window.chickadeeSaveNotebook, the idle-logout flush) is wired
// through it. It:
//
//   1. Boots the editor on the real student page; the seeded starter cell
//      renders and the kernel reaches idle.
//   2. Types a unique marker (CKBRIDGE_<stamp>) into cell 0 — but does NOT press
//      Ctrl+S, so the ONLY thing that can save is the bridge.
//   3. From the PARENT page, imports the vendored host bundle, builds the bridge
//      against iframe#jl-frame, awaits `.ready`, asserts `listCommands()` RPCs
//      back an array containing "docmanager:save" (a real round-trip that
//      returns data), then `execute("docmanager:save")`. A regression here fails
//      even if the jupyterapp fallback would have saved.
//   4. Types a second marker (CKPROD_<stamp>) and calls the MIGRATED production
//      helper window.chickadeeSaveNotebook() — the idle-logout flush now routed
//      through the bridge in notebook.js.
//   5. Reloads the same context and asserts BOTH markers survived — i.e. the
//      direct bridge save AND the production save path wrote to the Drive.
//
// A PASS means the bridge can READ (listCommands) and DRIVE (execute) the
// in-iframe JupyterLab app from the parent, and that the migrated production
// save path persists through it on the 0.8 stack.
//
// Seeds through the real HTTP API exactly like notebook-lifecycle-check.mjs.
//
// Usage:  node notebook-bridge-check.mjs <baseURL>
// Env:    SMOKE_BROWSER (chromium|webkit|firefox), SMOKE_KERNEL_MS.
// Exit 0 = bridge healthy; exit 1 = a step failed (details printed).

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
const BRIDGE_READY_MS = 30_000;
const FRAME_ID = "jl-frame";

const STAMP = Date.now().toString(36);
const STARTER_MARKER = "CKSTARTER";
const BRIDGE_MARKER = `CKBRIDGE_${STAMP}`;
const PROD_MARKER = `CKPROD_${STAMP}`;
const STARTER_SOURCE = `# ${STARTER_MARKER}\nx = 1\n`;

const INSTRUCTOR = { username: `br_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `br_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `BR${STAMP}`.slice(0, 12), name: "Bridge Course" };

const MANIFEST = JSON.stringify({
  schemaVersion: 1,
  gradingMode: "browser",
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }],
  timeLimitSeconds: 10,
  makefile: null,
});

function fail(reason, extra) {
  console.log(`BRIDGE FAIL — ${reason}`);
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

// Seed via the real HTTP API (mirrors notebook-lifecycle-check.mjs).
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

async function findEditorFrame(page) {
  for (let i = 0; i < 60; i++) {
    const fr = page.frames().find((f) => /\/jupyterlite\//.test(f.url()));
    if (fr) return fr;
    await page.waitForTimeout(500);
  }
  return null;
}

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

async function waitForKernelIdle(page) {
  const deadline = Date.now() + IDLE_WAIT_MS;
  while (Date.now() < deadline) {
    const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
    if (diag.some((d) => d.kind === "kernel_phase" && d.source === "kernel_idle")) return true;
    await page.waitForTimeout(500);
  }
  return false;
}

async function bodyText(jlFrame) {
  return await jlFrame.evaluate(() => (document.body && document.body.innerText) || "").catch(() => "");
}

// Type a marker comment into cell 0 to make the document dirty, WITHOUT saving.
// (The bridge is the only thing that may save in this probe.) Mirrors the
// lifecycle check's cell editing minus the Ctrl+S.
async function typeMarkerIntoCell(page, jlFrame, marker) {
  const cell = jlFrame.locator(".jp-Notebook .jp-CodeCell .cm-content").first();
  try {
    await cell.click({ timeout: 15_000 });
  } catch (e) {
    return "could not focus the cell editor: " + (e && e.message ? e.message : e);
  }
  await page.waitForTimeout(300);
  await page.keyboard.press("Control+End").catch(() => {});
  await page.keyboard.type(`\n# ${marker}\n`);
  await page.waitForTimeout(300);
  const registered = await jlFrame
    .evaluate((m) => ((document.body && document.body.innerText) || "").includes(m), marker)
    .catch(() => false);
  if (!registered) return "edit did not register in the editor (typing into CodeMirror failed)";
  return "ok";
}

// Build the command bridge in the PARENT page and drive docmanager:save.
// Runs entirely inside the page (dynamic-imports the vendored host bundle).
// Returns { ok, detail, commandCount }.
async function driveSaveViaBridge(page) {
  return await page.evaluate(async ({ frameId, readyMs }) => {
    const withTimeout = (p, ms, label) =>
      Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`${label} timed out after ${ms}ms`)), ms))]);
    try {
      let mod;
      try {
        mod = await import("/vendor/iframe-commands-host.js");
      } catch (e) {
        return { ok: false, detail: "could not import /vendor/iframe-commands-host.js: " + (e && e.message || e) };
      }
      if (typeof mod.createBridge !== "function") {
        return { ok: false, detail: "createBridge is not exported from the host bundle" };
      }
      let bridge;
      try {
        bridge = mod.createBridge({ iframeId: frameId });
      } catch (e) {
        return { ok: false, detail: "createBridge threw: " + (e && e.message || e) };
      }
      try {
        await withTimeout(Promise.resolve(bridge.ready), readyMs, "bridge.ready");
      } catch (e) {
        return { ok: false, detail: (e && e.message || String(e)) + " — the in-iframe extension never exposed the command bridge" };
      }
      // Round-trip RPC that returns data: the command registry must include save.
      let commands;
      try {
        commands = await withTimeout(Promise.resolve(bridge.listCommands()), readyMs, "listCommands()");
      } catch (e) {
        return { ok: false, detail: "listCommands() RPC failed: " + (e && e.message || e) };
      }
      const count = Array.isArray(commands) ? commands.length : 0;
      if (!Array.isArray(commands) || !commands.includes("docmanager:save")) {
        return { ok: false, detail: `docmanager:save absent from listCommands() (got ${count} commands)`, commandCount: count };
      }
      // Drive the real save command through the bridge.
      try {
        await withTimeout(Promise.resolve(bridge.execute("docmanager:save")), readyMs, "execute(docmanager:save)");
      } catch (e) {
        return { ok: false, detail: "execute(docmanager:save) RPC failed: " + (e && e.message || e), commandCount: count };
      }
      return { ok: true, detail: "executed docmanager:save via the bridge", commandCount: count };
    } catch (e) {
      return { ok: false, detail: "bridge exception: " + (e && e.stack || e) };
    }
  }, { frameId: FRAME_ID, readyMs: BRIDGE_READY_MS });
}

// Drive the MIGRATED production save path: notebook.js's window.chickadeeSaveNotebook
// (the idle-logout flush) now routes through executeEditorCommand → the bridge
// (with a jupyterapp fallback). Calling it from the parent page proves the
// production wiring, not just an ad-hoc bridge. Returns { ok, detail }.
async function driveProductionSave(page) {
  return await page.evaluate(async () => {
    if (typeof window.chickadeeSaveNotebook !== "function") {
      return { ok: false, detail: "window.chickadeeSaveNotebook is not defined (notebook.js not loaded / not wired)" };
    }
    try {
      await window.chickadeeSaveNotebook();
      return { ok: true, detail: "called window.chickadeeSaveNotebook()" };
    } catch (e) {
      return { ok: false, detail: "chickadeeSaveNotebook() threw: " + (e && e.message || e) };
    }
  });
}

async function main() {
  console.log(`Browser engine: ${browserName}`);
  console.log(`Seeding browser-graded assignment via ${baseURL} …`);
  let seeded;
  try { seeded = await seed(); }
  catch (e) { return fail(`seeding failed: ${(e && e.message) || e}`); }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`Seeded setup ${seeded.setupID}; driving bridge probe on ${notebookURL}`);

  const launchOptions =
    browserName === "chromium"
      ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
      : { headless: true };
  const browser = await browserType.launch(launchOptions);
  // ONE context for the whole run so the IndexedDB Drive persists across reload.
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

    // ---- Step 2: dirty the document (no Ctrl+S) --------------------------
    const typed = await typeMarkerIntoCell(page, jlFrame, BRIDGE_MARKER);
    if (typed !== "ok") return fail(`could not type the marker into the notebook: ${typed}`);
    console.log("step 2 ok: typed marker into cell 0 (unsaved)");

    // ---- Step 3: drive docmanager:save THROUGH THE BRIDGE directly -------
    // Proves the bridge MECHANISM (a regression here fails even if the
    // jupyterapp fallback would have saved).
    const bridge = await driveSaveViaBridge(page);
    if (!bridge.ok) return fail(`bridge could not drive the save: ${bridge.detail}`);
    console.log(`step 3 ok: ${bridge.detail} (listCommands → ${bridge.commandCount} commands)`);

    // ---- Step 4: drive the MIGRATED production save path -----------------
    // Dirty the doc again, then call window.chickadeeSaveNotebook() — the
    // idle-logout flush now wired through the bridge in notebook.js.
    const typed2 = await typeMarkerIntoCell(page, jlFrame, PROD_MARKER);
    if (typed2 !== "ok") return fail(`could not type the production marker: ${typed2}`);
    const prod = await driveProductionSave(page);
    if (!prod.ok) return fail(`production save path failed: ${prod.detail}`);
    console.log(`step 4 ok: ${prod.detail}`);

    // ---- Step 5: reload and assert BOTH saves persisted ------------------
    await page.waitForTimeout(2000); // let the Drive write flush
    console.log("step 5: reloading to confirm both saves reached the Drive…");
    await page.reload({ waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    jlFrame = await findEditorFrame(page);
    if (!jlFrame) return fail("editor iframe never re-attached after save + reload");
    if (!(await waitForEditorWithSource(jlFrame, STARTER_MARKER))) {
      return fail("editor did not re-render the notebook after save + reload", (await bodyText(jlFrame)).slice(0, 300));
    }
    for (const [label, marker, why] of [
      ["bridge", BRIDGE_MARKER, "bridge execute(docmanager:save) did not persist to the Drive"],
      ["production", PROD_MARKER, "window.chickadeeSaveNotebook() (migrated to the bridge) did not persist to the Drive"],
    ]) {
      const ok = await jlFrame.waitForFunction(
        (needle) => ((document.body && document.body.innerText) || "").includes(needle),
        marker, { timeout: 30_000 }
      ).then(() => true).catch(() => false);
      if (!ok) {
        return fail(`${label} marker did NOT survive reload — ${why}`, (await bodyText(jlFrame)).slice(0, 300));
      }
      console.log(`step 5 ok: ${label} save persisted across reload`);
    }

    console.log(`BRIDGE PASS — jupyter-iframe-commands bridge drove docmanager:save directly AND via the migrated window.chickadeeSaveNotebook on the real 0.8 editor (engine=${browserName})`);
    await finish(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`);
  }
}

main();
