// bare-notebook-check.mjs — isolation experiment for the editor exec_hang.
//
// Seeds a browser-graded setup (same path as editor-exec-check), then navigates
// DIRECTLY to the bare JupyterLite *notebook app* the server hands us
// (data-editor-url), bypassing Chickadee's /testsetups/:id/notebook wrapper
// page entirely — no iframe, no notebook.js, no browser-runner, no
// freeze-watchdog. Same kernel, same Drive-seeded notebook. Then runs the
// seeded cell and asserts its stdout.
//
// If the REPL passes (it does) and the FULL wrapper page hangs, this tells us
// whether the hang lives in the notebook app + Drive (bare app also hangs) or in
// our iframe/wrapper orchestration (bare app passes).
import { chromium } from "playwright";
import { request as pwRequest } from "playwright";
import JSZip from "jszip";

const baseURL = (process.argv[2] || "http://127.0.0.1:8137").replace(/\/$/, "");
const EXEC_TOKEN = "CKEXEC=42";
const NB_CELL_SOURCE = 'print("CKEXEC=%d" % (6 * 7))\n';
const STAMP = Date.now().toString(36);
const INSTRUCTOR = { username: `bq_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `bq_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `BQ${STAMP}`.slice(0, 12), name: "Bare Probe Course" };
const MANIFEST = JSON.stringify({
  schemaVersion: 1, gradingMode: "browser", requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }], timeLimitSeconds: 10, makefile: null,
});

function extractCsrf(html) {
  let m = html.match(/name=['"]_csrf['"][^>]*\svalue=['"]([^'"]+)['"]/i);
  if (m) return m[1];
  m = html.match(/\svalue=['"]([^'"]+)['"][^>]*name=['"]_csrf['"]/i);
  if (m) return m[1];
  return null;
}
async function csrfFrom(ctx, path) {
  const res = await ctx.get(path);
  const t = extractCsrf(await res.text());
  if (!t) throw new Error(`no CSRF on ${path} (${res.status()})`);
  return t;
}
async function ok(label, p, codes) {
  const res = await p;
  if (!codes.includes(res.status())) throw new Error(`${label}: ${res.status()}`);
  return res;
}
async function buildZip() {
  const zip = new JSZip();
  zip.file("assignment.ipynb", JSON.stringify({
    nbformat: 4, nbformat_minor: 5, metadata: { kernelspec: { name: "python", display_name: "Python" } },
    cells: [{ cell_type: "code", source: [NB_CELL_SOURCE], metadata: {}, outputs: [], execution_count: null }],
  }));
  zip.file("test_public.py", 'print("ok")\n');
  return zip.generateAsync({ type: "nodebuffer" });
}
async function seed() {
  const instr = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(instr, "/register");
  await ok("reg instr", instr.post("/register", { form: { username: INSTRUCTOR.username, password: INSTRUCTOR.password, _csrf: csrf }, maxRedirects: 0 }), [200, 302, 303]);
  csrf = await csrfFrom(instr, "/admin/courses/new");
  const cr = await ok("course", instr.post("/admin/courses", { form: { code: COURSE.code, name: COURSE.name, _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }), [302, 303]);
  const courseID = ((cr.headers()["location"] || "").match(/courses\/([0-9a-fA-F-]{36})/) || [])[1];
  await ok("enroll-mode", instr.post(`/courses/${courseID}/enrollment-mode`, { form: { enrollmentMode: "auto", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }), [302, 303]);
  const zipBuf = await buildZip();
  csrf = await csrfFrom(instr, "/");
  const sr = await ok("setup", instr.post("/api/v1/testsetups", { multipart: { manifest: MANIFEST, courseID, files: { name: "setup.zip", mimeType: "application/zip", buffer: zipBuf } }, headers: { "x-csrf-token": csrf } }), [200, 201]);
  const setupID = JSON.parse(await sr.text()).testSetupID;
  await instr.dispose();
  const stud = await pwRequest.newContext({ baseURL });
  csrf = await csrfFrom(stud, "/register");
  await ok("reg stud", stud.post("/register", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }), [200, 302, 303]);
  csrf = await csrfFrom(stud, "/login");
  await ok("login", stud.post("/login", { form: { username: STUDENT.username, password: STUDENT.password, _csrf: csrf }, maxRedirects: 0 }), [200, 302, 303]);
  const storageState = await stud.storageState();
  await stud.dispose();
  return { setupID, storageState };
}

const { setupID, storageState } = await seed();
const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ storageState });
const page = await ctx.newPage();
const errors = [];
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text().slice(0, 200)); });
page.on("pageerror", (e) => errors.push("PAGEERR msg=[" + ((e && e.message) || "").slice(0, 1200) + "] name=" + ((e && e.name) || "")));
// Also surface kernel stderr/console (the kernel logs its own traceback there).
page.on("console", (m) => { const t = m.text(); if (/Traceback|Error|Exception|raise |File \"|line \d|drive|Drive/.test(t)) errors.push("CONSOLE " + t.slice(0, 600)); });
// Track drive/contents/files requests; anything still PENDING at hang time means
// the kernel is wedged waiting on it (the DriveFS-over-missing-transport case).
const pending = new Map();
page.on("request", (r) => { const u = r.url(); if (/\/api\/(drive|contents)\/|\/files\/|\/api\/drive/.test(u)) pending.set(r, `${r.method()} ${u.replace(/^https?:\/\/[^/]+/, "")}`); });
page.on("requestfinished", (r) => pending.delete(r));
page.on("requestfailed", (r) => { if (pending.has(r)) { errors.push("REQFAIL " + pending.get(r) + " — " + (r.failure()?.errorText || "")); pending.delete(r); } });

// Pull the server's exact bare-app editor URL (correct path incl. userID).
const wrap = await page.goto(`${baseURL}/testsetups/${setupID}/notebook`, { waitUntil: "domcontentloaded" });
const html = await wrap.text();
const m = html.match(/data-editor-url=['"]([^'"]+)['"]/i);
if (!m) { console.log("BARE: could not find data-editor-url"); process.exit(2); }
const editorURL = m[1].replace(/&amp;/g, "&");
console.log("BARE notebook app URL:", editorURL);

// Navigate the TOP-LEVEL page directly to the bare notebook app (no iframe).
await page.goto(`${baseURL}${editorURL}`, { waitUntil: "domcontentloaded" });

// Wait for the notebook + the seeded cell to render.
const rendered = await page.waitForFunction(() => {
  const jp = document.querySelectorAll("[class^='jp-'],[class*=' jp-']").length;
  const text = (document.body && document.body.innerText) || "";
  return jp > 20 && /CKEXEC/.test(text);
}, null, { timeout: 120000 }).then(() => true).catch(() => false);
if (!rendered) { console.log("BARE: notebook never rendered the seeded cell"); console.log(errors.slice(0, 8).join("\n")); process.exit(1); }
console.log("BARE: notebook rendered the cell; waiting for idle then running");

// Wait for an execution indicator to settle to idle.
await page.waitForTimeout(8000);
const cell = page.locator(".jp-Notebook .jp-CodeCell .cm-content").first();
await cell.click({ timeout: 15000 });
await cell.press("Shift+Enter");

const start = Date.now();
let ran = false;
while (Date.now() - start < 60000) {
  const body = await page.evaluate(() => (document.body && document.body.innerText) || "").catch(() => "");
  if (body.includes(EXEC_TOKEN)) { ran = true; break; }
  await page.waitForTimeout(500);
}
console.log(`BARE RESULT — ${ran ? "PASS (cell executed)" : "HANG (cell never produced output)"} after ${Date.now() - start}ms`);
if (!ran) {
  for (const [, desc] of pending) errors.push("PENDING-AT-HANG " + desc);
  console.log("errors:\n" + errors.slice(0, 16).join("\n"));
}
await browser.close();
process.exit(ran ? 0 : 1);
