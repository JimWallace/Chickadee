// notebook-reset-check.mjs
//
// Headless END-TO-END check that instructor/self "Reset notebook" actually
// takes effect in the JupyterLite 0.8 editor — the regression this confirms and
// guards: the 0.8 Notebook build doesn't expose `window.jupyterapp`, so the
// client reseed (`syncNotebookFromServerSnapshot`) that makes a reset visible
// silently no-op'd, leaving the student's stale IndexedDB copy on screen.
//
// Flow (one student, one browser context so the IndexedDB Drive persists across
// reloads):
//   1. Boot the assignment editor; the seeded starter (CKSTART) renders, kernel idle.
//   2. Append a unique edit marker (CKEDIT_<stamp>) to cell 0 and Ctrl+S — now the
//      student's IndexedDB working copy differs from the server starter.
//   3. POST the self-reset endpoint, which overwrites the server working copy back
//      to the starter (bumping its mtime).
//   4. Reload. The reset must be visible: the edit marker is GONE and the starter
//      marker is present. WITHOUT the fix the stale IndexedDB copy survives and
//      CKEDIT is still there -> FAIL; WITH the fix the Drive entry is evicted and
//      the editor re-fetches the reset starter from the server -> the marker is gone.
//
// Unlike notebook-lifecycle-check.mjs (a bare test setup), reset needs a published,
// open assignment (requireOpenStudentAssignment), so this seeds one through the
// instructor draft/publish HTTP flow. Publishing with NO test suite skips the
// validation run, so no worker/runner is required.
//
// Usage:  node notebook-reset-check.mjs <baseURL>
// Env:    SMOKE_BROWSER (chromium|webkit|firefox), SMOKE_KERNEL_MS.
// Exit 0 = reset works; exit 1 = a step failed (details printed).

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

const INSTRUCTOR = { username: `rs_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `rs_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `RS${STAMP}`.slice(0, 12), name: "Reset Course" };
const ASSIGNMENT_NAME = `Reset Lab ${STAMP}`;

function fail(reason, extra) {
  console.log(`RESET FAIL — ${reason}`);
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
    instr.post("/admin/courses", { form: { code: COURSE.code, name: COURSE.name, _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
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
  const publicID = (instrHtml.match(/\/instructor\/([A-Za-z0-9]+)\/edit/) || [])[1];
  if (!publicID) {
    const markers = {
      finalURL: instrDash.url(),
      hasNoAssignments: instrHtml.includes("No assignments"),
      hasEditLink: instrHtml.includes("/edit"),
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

async function main() {
  console.log(`Browser engine: ${browserName}`);
  console.log(`Seeding published assignment via ${baseURL} …`);
  let seeded;
  try { seeded = await seed(); }
  catch (e) { return fail(`seeding failed: ${(e && e.message) || e}`); }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`Seeded setup ${seeded.setupID}; driving reset check on ${notebookURL}`);

  const launchOptions = browserName === "chromium"
    ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
    : { headless: true };
  const browser = await browserType.launch(launchOptions);
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
    // ---- Step 1: boot, render starter, kernel idle ----------------------
    await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    if (/\/login/.test(page.url())) return fail(`redirected to login — student not authorized (url=${page.url()})`);
    let jlFrame = await findEditorFrame(page);
    if (!jlFrame) return fail("the JupyterLite editor iframe never attached");
    if (!(await waitForEditorWithSource(jlFrame, STARTER_MARKER))) {
      return fail("editor never rendered the seeded starter cell", (await bodyText(jlFrame)).slice(0, 300));
    }
    if (!(await waitForKernelIdle(page))) return fail("kernel never reported idle");
    console.log("step 1 ok: editor booted, starter rendered, kernel idle");

    // ---- Step 2: edit + save (diverge from the server starter) ----------
    const editResult = await editCellAndSave(page, jlFrame, EDIT_MARKER);
    if (editResult !== "ok") return fail(`could not edit + save the notebook: ${editResult}`);
    console.log("step 2 ok: edited cell 0 and saved to the Drive");

    // ---- Step 3: trigger the self-reset endpoint ------------------------
    // Wait so the reset's working-copy mtime is strictly newer than the one the
    // editor recorded on first open (1s filesystem mtime resolution).
    await page.waitForTimeout(2500);
    const resetCtx = await pwRequest.newContext({ baseURL, storageState: seeded.storageState });
    let resetCsrf;
    try { resetCsrf = await csrfFrom(resetCtx, "/"); }
    catch (e) { return fail(`could not get CSRF for reset: ${(e && e.message) || e}`); }
    const resetRes = await resetCtx.post(`/testsetups/${seeded.setupID}/reset-notebook`, {
      form: { _csrf: resetCsrf }, headers: { "x-csrf-token": resetCsrf }, maxRedirects: 0,
    });
    if (![200, 302, 303].includes(resetRes.status())) {
      let b = ""; try { b = (await resetRes.text()).slice(0, 300); } catch { /* ignore */ }
      return fail(`reset endpoint returned ${resetRes.status()}`, b);
    }
    await resetCtx.dispose();
    console.log("step 3 ok: server working copy reset to the starter");

    // ---- Step 4: reload and assert the reset is visible -----------------
    await page.waitForTimeout(1500);
    console.log("step 4: reloading to confirm the reset is visible…");
    await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    jlFrame = await findEditorFrame(page);
    if (!jlFrame) return fail("editor iframe never re-attached after reset + reload");
    if (!(await waitForEditorWithSource(jlFrame, STARTER_MARKER))) {
      return fail("editor did not re-render the notebook after reset + reload", (await bodyText(jlFrame)).slice(0, 300));
    }
    // The fix may itself reload the iframe (reset=1) — give the re-seed a moment.
    await page.waitForTimeout(4000);
    const stillEdited = await jlFrame
      .evaluate((m) => ((document.body && document.body.innerText) || "").includes(m), EDIT_MARKER)
      .catch(() => false);
    if (stillEdited) {
      return fail(
        "the student's edit marker SURVIVED the reset — reset did not take effect " +
          "(the 0.8 reseed regression: stale IndexedDB copy not replaced by the server starter)",
        (await bodyText(jlFrame)).slice(0, 300)
      );
    }
    console.log("step 4 ok: edit marker gone — reset is visible on the 0.8 editor");

    console.log(`RESET PASS — instructor/self reset takes effect on the real 0.8 notebook editor (engine=${browserName})`);
    await finish(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`);
  }
}

main();
