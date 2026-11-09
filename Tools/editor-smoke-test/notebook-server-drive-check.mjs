// notebook-server-drive-check.mjs
//
// Spike for #469: does the server-backed editor drive work end to end?
//
// The server adds `chickadeeServerDrive` to the served jupyter-lite.json (the
// default; the `ck_server_drive=0` cookie opts out), and the Chickadee extension then replaces
// JupyterLite's IndexedDB drive with JupyterLab's REST drive, which saves to
// `PUT /jupyterlite/api/contents/<path>` (JupyterLiteContentsRoutes+Write.swift).
//
// Flow (one student, a published open no-suite assignment, as in
// notebook-reset-check.mjs, whose seeding and editor helpers this copies):
//   1. Boot the editor with the cookie. The extension logs that the server
//      drive is active; the starter renders; the kernel is idle.
//   2. Edit cell 0 and press Ctrl+S. A PUT returns 200 and the server's working
//      copy now holds the edit. Nothing is written to IndexedDB.
//   3. The kernel writes a file next to the notebook and reads the notebook
//      back: kernel file I/O goes through the same drive, so the file reaches
//      the server.
//   4. A second, fresh browser context (a new device: empty IndexedDB) opens
//      the notebook and sees the edit.
//   5. Reset on the server, then Ctrl+S in the still-open first editor:
//      JupyterLab's own last_modified check raises its "File changed" dialog,
//      so the reset is not overwritten silently.
//   6. Reload the first editor: the reset starter is shown, with no IndexedDB
//      eviction needed.
//
// Control: SMOKE_SERVER_DRIVE=0 runs the same flow with the opt-out cookie. Step 1
// then fails (no server drive), which shows the check can tell the two apart.
//
// Usage:  node notebook-server-drive-check.mjs <baseURL>
// Env:    SMOKE_BROWSER (chromium|webkit|firefox), SMOKE_KERNEL_MS,
//         SMOKE_SERVER_DRIVE (default 1).
// Exit 0 = the server drive works; exit 1 = a step failed (details printed).

import { chromium, webkit, firefox } from "playwright";
import { request as pwRequest } from "playwright";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");

const PAGE_LOAD_MS = 30_000;
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
const IDLE_WAIT_MS = 90_000;

const STAMP = Date.now().toString(36);
const STARTER_MARKER = "CKSTART";
const EDIT_MARKER = `CKEDIT_${STAMP}`;
const STARTER_SOURCE = `# ${STARTER_MARKER}\nx = 1\n`;

const INSTRUCTOR = { username: `sd_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `sd_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `SD${STAMP}`.slice(0, 12), name: "Server Drive Course" };
const ASSIGNMENT_NAME = `Server Drive Lab ${STAMP}`;

function fail(reason, extra) {
  console.log(`SERVER-DRIVE FAIL — ${reason}`);
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

function starterNotebookBuffer() {
  const nb = {
    nbformat: 4, nbformat_minor: 5,
    metadata: { kernelspec: { name: "python", display_name: "Python" } },
    cells: [{ cell_type: "code", source: [STARTER_SOURCE], metadata: {}, outputs: [], execution_count: null }],
  };
  return Buffer.from(JSON.stringify(nb), "utf8");
}

// Seed an instructor, an auto-enroll course, a PUBLISHED OPEN no-suite assignment,
// and a student (auto-enrolled). Returns { storageState } for the student plus the
// assignment's setupID + notebook URL discovered from the student dashboard.
async function seed() {
  const instr = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(instr, "/register");
  await expectOK("register instructor",
    instr.post("/register", { form: { username: INSTRUCTOR.username, password: INSTRUCTOR.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);

  csrf = await csrfFrom(instr, "/admin/courses/new");
  const courseRes = await expectOK("create course",
    instr.post("/admin/courses", { form: { code: COURSE.code, name: COURSE.name, termYear: "2026", termSeason: "fall", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
    [302, 303]);
  const loc = courseRes.headers()["location"] || "";
  const courseID = (loc.match(/\/admin\/courses\/([0-9a-fA-F-]{36})/) || [])[1];
  if (!courseID) throw new Error(`could not parse courseID from redirect: "${loc}"`);
  await expectOK("set enrollment auto",
    instr.post(`/courses/${courseID}/enrollment-mode`, { form: { enrollmentMode: "auto", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
    [302, 303]);

  // Publish a no-suite assignment (single starter notebook). An empty test suite
  // skips the validation run, so no runner is needed. The instructor's single
  // enrolled course is auto-selected as active.
  csrf = await csrfFrom(instr, "/instructor/new");
  // A successful publish redirects to exactly /instructor; a FAILED one
  // redirects (also 302) back to /instructor/new?...&error=... — so inspect the
  // redirect target, not just the status, and surface the error reason.
  const pubRes = await instr.post("/instructor/new/save", {
    multipart: {
      _csrf: csrf,
      draftID: "",
      assignmentName: ASSIGNMENT_NAME,
      dueAt: "",
      startsAt: "",
      sectionID: "",
      requiredLanguagesCSV: "",
      requiredCapabilitiesCSV: "",
      assignmentNotebookFile: { name: "assignment.ipynb", mimeType: "application/json", buffer: starterNotebookBuffer() },
      // Publish requires a solution notebook ("Solution notebook (.ipynb) is required").
      solutionNotebookFile: { name: "solution.ipynb", mimeType: "application/json", buffer: starterNotebookBuffer() },
    },
    headers: { "x-csrf-token": csrf },
    maxRedirects: 0,
  });
  if (![302, 303].includes(pubRes.status())) {
    let body = ""; try { body = (await pubRes.text()).slice(0, 800); } catch { /* ignore */ }
    throw new Error(`publish assignment: status ${pubRes.status()} (wanted a redirect)\n${body}`);
  }
  const pubLoc = pubRes.headers()["location"] || "";
  if (pubLoc.startsWith("/instructor/new")) {
    let errPage = "";
    try { errPage = (await (await instr.get(pubLoc)).text()).slice(0, 1500); } catch { /* ignore */ }
    throw new Error(`publish failed — redirected to ${decodeURIComponent(pubLoc)}\n${errPage}`);
  }
  // Find the published assignment from the INSTRUCTOR dashboard (reliable — no
  // student visibility gating) and OPEN it: createNewAssignmentRow publishes
  // with visibility=.closed, so the student can't see it until it's opened. A
  // no-suite assignment has validationStatus=nil, which setOpenState permits to
  // open without a runner.
  // Grab the assignment's publicID from the INSTRUCTOR dashboard and OPEN it:
  // createNewAssignmentRow publishes with visibility=.closed, so the student
  // can't see it until it's opened. A no-suite assignment has
  // validationStatus=nil, which setOpenState permits to open without a runner.
  // (setupID is NOT reliably on /instructor for a fresh closed row — the hidden
  // testSetupID input only renders in submission/retest forms — so we read it
  // from the student dashboard once the assignment is open.)
  const instrDash = await instr.get("/instructor");
  const instrHtml = await instrDash.text();
  // The dashboard's per-assignment link is the only place the publicID appears
  // in this markup, so this scrape is load-bearing. It accepts both targets
  // because that link has moved once already — it pointed at `/edit` until the
  // workbench became the authoring surface — and a probe that hard-codes one
  // spelling fails with "could not find publicID" rather than anything that
  // points at the rename.
  const publicID =
    (instrHtml.match(/\/instructor\/([A-Za-z0-9]+)\/(?:workbench|edit)/) || [])[1];
  if (!publicID) {
    const markers = {
      finalURL: instrDash.url(),
      hasNoAssignments: instrHtml.includes("No assignments"),
      hasEditLink: instrHtml.includes("/edit"),
      hasWorkbenchLink: instrHtml.includes("/workbench"),
      len: instrHtml.length,
    };
    throw new Error(`could not find publicID on /instructor markers=${JSON.stringify(markers)}:\n` + instrHtml.slice(0, 3500));
  }
  csrf = await csrfFrom(instr, "/instructor");
  await expectOK("open assignment",
    instr.post(`/instructor/${publicID}/open`, { form: { _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
    [302, 303]);
  await instr.dispose();

  // Student registers + logs in; an auto-enroll course enrolls them on the next
  // authenticated course-state resolution. They reach the now-open assignment
  // directly at /testsetups/:setupID/notebook (no dashboard scraping needed).
  const stud = await pwRequest.newContext({ baseURL });
  csrf = await csrfFrom(stud, "/register");
  await expectOK("register student",
    stud.post("/register", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  csrf = await csrfFrom(stud, "/login");
  await expectOK("login student",
    stud.post("/login", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  // The assignment is now OPEN, so it appears on the student dashboard with the
  // reset form (action=/testsetups/:id/reset-notebook, gated on isOpen &&
  // hasNotebook) — read the setupID from there. The GET also commits the
  // auto-enroll into the .auto course.
  const dashHtml = await (await stud.get("/")).text();
  const setupID = (dashHtml.match(/\/testsetups\/([A-Za-z0-9_-]+)\/(?:reset-notebook|notebook|submit)/) || [])[1];
  if (!setupID) {
    throw new Error(
      "could not find setupID on the student dashboard after opening the assignment " +
        `(hasNoAssignments=${dashHtml.includes("No assignments")}):\n` + dashHtml.slice(0, 3000));
  }
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

async function editCellAndSave(page, jlFrame, marker) {
  const cell = jlFrame.locator(".jp-Notebook .jp-CodeCell .cm-content").first();
  try { await cell.click({ timeout: 15_000 }); }
  catch (e) { return "could not focus the cell editor: " + (e && e.message ? e.message : e); }
  await page.waitForTimeout(300);
  await page.keyboard.press("Control+End").catch(() => {});
  await page.keyboard.type(`\n# ${marker}\n`);
  await page.waitForTimeout(300);
  const registered = await jlFrame
    .evaluate((m) => ((document.body && document.body.innerText) || "").includes(m), marker)
    .catch(() => false);
  if (!registered) return "edit did not register in the editor (typing into CodeMirror failed)";
  await page.keyboard.press("Control+s");
  await page.waitForTimeout(2000);
  return "ok";
}

// Diagnostic: from a page OR frame context, list IndexedDB databases and the
// "JupyterLite Storage" files-store keys. Reveals whether the parent can see
// the iframe's Drive DB and the exact key format the eviction must match.
async function dumpDrive(ctx) {
  return await ctx.evaluate(async () => {
    const out = { dbs: [], filesKeys: null, err: null };
    try {
      const dbs = await indexedDB.databases();
      out.dbs = dbs.map((d) => d.name).filter(Boolean);
    } catch (e) { out.err = "databases(): " + (e && e.message || e); }
    const driveName = out.dbs.find((n) => typeof n === "string" && n.indexOf("JupyterLite Storage") === 0);
    if (driveName) {
      out.filesKeys = await new Promise((resolve) => {
        let done = false;
        const finish = (v) => { if (!done) { done = true; resolve(v); } };
        setTimeout(() => finish("(timeout)"), 4000);
        try {
          const req = indexedDB.open(driveName);
          req.onerror = () => finish("(open error)");
          req.onsuccess = () => {
            const db = req.result;
            if (!db.objectStoreNames.contains("files")) { db.close(); return finish("(no files store)"); }
            const kr = db.transaction("files", "readonly").objectStore("files").getAllKeys();
            kr.onsuccess = () => { db.close(); finish((kr.result || []).map((k) => (typeof k === "object" ? JSON.stringify(k) : String(k)))); };
            kr.onerror = () => { db.close(); finish("(getAllKeys error)"); };
          };
        } catch (e) { finish("(exception " + (e && e.message || e) + ")"); }
      });
    }
    return out;
  }).catch((e) => ({ err: "evaluate failed: " + (e && e.message || e) }));
}


const SERVER_DRIVE = process.env.SMOKE_SERVER_DRIVE !== "0";
const PROBE_FILE = `ck_probe_${STAMP}.txt`;
const PROBE_DIR = `ck_dir_${STAMP}`;

// The server drive is the default, so the main run sets no cookie and proves
// the default; the control run opts this browser out.
function optOutCookie() {
  const url = new URL(baseURL);
  return { name: "ck_server_drive", value: "0", domain: url.hostname, path: "/" };
}

/// A browser context for the seeded student, with the control run's opt-out cookie and the
/// kernel-diag listener, and a log of console lines and contents-API calls.
async function newStudentContext(browser, storageState) {
  const context = await browser.newContext({ storageState });
  if (!SERVER_DRIVE) await context.addCookies([optOutCookie()]);
  await context.addInitScript(() => {
    try {
      window.__ckKernelDiag = [];
      window.addEventListener("message", (e) => {
        const d = e && e.data;
        if (d && d.ck === "kernel-diag") window.__ckKernelDiag.push({ kind: d.kind, source: d.source, message: d.message });
      });
    } catch (_) { /* ignore */ }
  });
  const log = { console: [], contents: [] };
  context.on("console", (msg) => log.console.push(msg.text()));
  context.on("response", (res) => {
    const u = new URL(res.url());
    if (u.pathname.includes("/api/contents/")) {
      log.contents.push(`${res.request().method()} ${res.status()} ${decodeURIComponent(u.pathname)}`);
    }
  });
  return { context, log };
}

async function bootEditor(page, notebookURL, mustContain) {
  await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
  if (/\/login/.test(page.url())) throw new Error(`redirected to login (url=${page.url()})`);
  const jlFrame = await findEditorFrame(page);
  if (!jlFrame) throw new Error("the JupyterLite editor iframe never attached");
  if (!(await waitForEditorWithSource(jlFrame, mustContain))) {
    throw new Error(`editor never rendered "${mustContain}": ${(await bodyText(jlFrame)).slice(0, 300)}`);
  }
  return jlFrame;
}

/// Runs `source` in a new cell at the end of the notebook and waits for
/// `expect` to appear in the editor's text.
async function runCell(page, jlFrame, source, expect) {
  const cell = jlFrame.locator(".jp-Notebook .jp-CodeCell .cm-content").last();
  await cell.click({ timeout: 15_000 });
  await page.keyboard.press("Escape");
  await page.keyboard.press("b");
  await page.keyboard.press("Enter");
  await page.keyboard.type(source);
  await page.keyboard.press("Shift+Enter");
  // Wait for the cell's output, not the page text: the cell's own source
  // contains the needle too.
  return await jlFrame.waitForFunction(
    (needle) => [...document.querySelectorAll(".jp-OutputArea-output")].some((n) => n.innerText.includes(needle)),
    expect, { timeout: 60_000 }
  ).then(() => true).catch(() => false);
}

/// The student's working-copy notebook, read through the contents API.
async function serverNotebook(api, dirPath) {
  const listing = await (await api.get(`/jupyterlite/api/contents/${dirPath}?content=1`)).json();
  const nb = (listing.content || []).find((c) => c.type === "notebook");
  if (!nb) return null;
  const model = await (await api.get(`/jupyterlite/api/contents/${nb.path}?content=1`)).json();
  return { path: nb.path, name: nb.name, text: JSON.stringify(model.content), listing };
}

async function main() {
  console.log(`Browser engine: ${browserName}; server drive ${SERVER_DRIVE ? "ON" : "OFF (control)"}`);
  let seeded;
  try { seeded = await seed(); }
  catch (e) { return fail(`seeding failed: ${(e && e.message) || e}`); }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`Seeded setup ${seeded.setupID}`);

  const launchOptions = browserName === "chromium"
    ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
    : { headless: true };
  if (process.env.SMOKE_BROWSER_PATH) launchOptions.executablePath = process.env.SMOKE_BROWSER_PATH;
  const browser = await browserType.launch(launchOptions);
  const api = await pwRequest.newContext({ baseURL, storageState: seeded.storageState });
  const a = await newStudentContext(browser, seeded.storageState);
  const page = await a.context.newPage();
  const finish = async (code) => { await browser.close(); process.exit(code); };
  const dump = () => "contents calls:\n  " + a.log.contents.slice(-25).join("\n  ");

  try {
    // ---- Step 1: boot with the server drive -----------------------------
    let jlFrame = await bootEditor(page, notebookURL, STARTER_MARKER);
    if (!(await waitForKernelIdle(page))) return fail("kernel never reported idle", dump());
    const active = a.log.console.some((l) => l.includes("[chickadee] server drive active"));
    if (!active) return fail("the server drive did not activate (no '[chickadee] server drive active' log)", dump());
    console.log("step 1 ok: server drive active, starter rendered, kernel idle");

    // ---- Step 2: edit + save goes to the server -------------------------
    const editResult = await editCellAndSave(page, jlFrame, EDIT_MARKER);
    if (editResult !== "ok") return fail(`could not edit + save: ${editResult}`, dump());
    const put = a.log.contents.find((l) => l.startsWith("PUT 200") && l.endsWith(".ipynb"));
    if (!put) return fail("no successful PUT of the notebook after Ctrl+S", dump());
    const userDir = put.replace(/^PUT 200 \/jupyterlite\/api\/contents\//, "").split("/").slice(0, 3).join("/");
    const saved = await serverNotebook(api, userDir);
    if (!saved || !saved.text.includes(EDIT_MARKER)) {
      return fail("the server working copy does not hold the edit", (saved && saved.text.slice(0, 300)) + "\n" + dump());
    }
    const idb = await dumpDrive(jlFrame);
    const idbFiles = Array.isArray(idb.filesKeys) ? idb.filesKeys : [];
    if (idbFiles.some((k) => k.includes(".ipynb"))) {
      return fail("the notebook was also written to IndexedDB", JSON.stringify(idb));
    }
    console.log(`step 2 ok: ${put}; server copy holds the edit; IndexedDB files: ${JSON.stringify(idb.filesKeys)}`);

    // ---- Step 3: kernel file I/O through the same drive ------------------
    const wrote = await runCell(page, jlFrame,
      `import os; os.makedirs('${PROBE_DIR}', exist_ok=True); open('${PROBE_FILE}', 'w').write('kernel-wrote-this'); print('NB_HEAD', open('${saved.name}').read()[:20].replace(chr(10), ' ')); print('ROOT=' + ','.join(os.listdir('/drive')) + ';')`,
      "ROOT=");
    if (!wrote) return fail("the kernel cell that writes a file and reads the notebook did not print", (await bodyText(jlFrame)).slice(-500));
    // The drive root lists `users` (not the student's folder contents), so the
    // kernel's `os.listdir('/drive')` sees the real tree.
    const rootOut = await jlFrame.evaluate(() =>
      [...document.querySelectorAll(".jp-OutputArea-output")].map((n) => n.innerText).join("\n")).catch(() => "");
    if (!rootOut.includes("ROOT=users;")) {
      return fail("os.listdir('/drive') did not list exactly users", rootOut.slice(-300));
    }
    // DriveFS flushes on close; give the PUT a moment to land.
    let probe = null;
    for (let i = 0; i < 20 && !probe; i++) {
      const res = await api.get(`/jupyterlite/api/contents/${userDir}/${PROBE_FILE}?content=1`);
      if (res.ok()) probe = await res.json();
      else await page.waitForTimeout(500);
    }
    if (!probe || probe.content !== "kernel-wrote-this") {
      return fail("the file the kernel wrote did not reach the server", JSON.stringify(probe) + "\n" + dump());
    }
    const dirRes = await api.get(`/jupyterlite/api/contents/${userDir}/${PROBE_DIR}`);
    const dirModel = dirRes.ok() ? await dirRes.json() : null;
    if (!dirModel || dirModel.type !== "directory") {
      return fail("the directory the kernel made (os.makedirs) did not reach the server", `${dirRes.status()}\n` + dump());
    }
    console.log("step 3 ok: kernel read the notebook and listed /drive as [users]; its written file and its os.makedirs directory reached the server");
    await page.keyboard.press("Control+s");
    await page.waitForTimeout(1500);

    // ---- Step 4: a fresh device sees the work ----------------------------
    const b = await newStudentContext(browser, seeded.storageState);
    const page2 = await b.context.newPage();
    try {
      await bootEditor(page2, notebookURL, EDIT_MARKER);
    } catch (e) {
      return fail(`a fresh browser context did not see the saved edit: ${(e && e.message) || e}`);
    }
    await b.context.close();
    console.log("step 4 ok: a fresh browser context (empty IndexedDB) opened the saved edit");

    // ---- Step 5: a server reset makes the next save raise a conflict -----
    await page.waitForTimeout(2500);
    let csrf = await csrfFrom(api, "/");
    const resetRes = await api.post(`/testsetups/${seeded.setupID}/reset-notebook`, {
      form: { _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0,
    });
    if (![200, 302, 303].includes(resetRes.status())) return fail(`reset endpoint returned ${resetRes.status()}`);
    const afterReset = await serverNotebook(api, userDir);
    if (!afterReset || afterReset.text.includes(EDIT_MARKER)) return fail("reset did not overwrite the server copy");
    const before = a.log.contents.length;
    await jlFrame.locator(".jp-Notebook .jp-CodeCell .cm-content").first().click();
    await page.keyboard.type(" ");
    await page.keyboard.press("Control+s");
    const dialog = await jlFrame.waitForFunction(
      () => ((document.body && document.body.innerText) || "").includes("has changed on disk"),
      null, { timeout: 15_000 }).then(() => true).catch(() => false);
    const overwrote = a.log.contents.slice(before).some((l) => l.startsWith("PUT 200") && l.endsWith(".ipynb"));
    if (!dialog || overwrote) {
      return fail(`after a server reset, Ctrl+S ${overwrote ? "overwrote the reset" : "raised no conflict dialog"}`, dump());
    }
    console.log("step 5 ok: Ctrl+S after a server reset raised JupyterLab's 'File changed' dialog, nothing overwritten");

    // ---- Step 6: reload shows the reset ----------------------------------
    jlFrame = await bootEditor(page, notebookURL, STARTER_MARKER);
    await page.waitForTimeout(3000);
    if ((await bodyText(jlFrame)).includes(EDIT_MARKER)) return fail("the edit survived the reset after a reload");
    console.log("step 6 ok: reload shows the reset starter, no IndexedDB eviction involved");

    console.log(`SERVER-DRIVE PASS (engine=${browserName})`);
    await finish(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`, dump());
  }
}

main();
