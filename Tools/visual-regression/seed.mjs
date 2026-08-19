// seed.mjs — fixture seeding over the real HTTP API, shared by capture.mjs
// (visual regression, #1136) and a11y.mjs (accessibility scan, #1137).
// Registers an instructor (first user becomes admin), creates an auto-enroll
// course, uploads a worker-graded test setup, publishes it into an OPEN
// assignment (so the student dashboard has rows to draw), registers + logs in
// a student, and submits once (stays pending — no runner attached).
import { request as pwRequest } from "playwright";
import JSZip from "jszip";

export const INSTRUCTOR = { username: "vis_instructor", password: "vis-instructor-pass-1" };
export const STUDENT = { username: "vis_student", password: "vis-student-pass-1" };
export const COURSE = { code: "VIS101", name: "Visual Regression 101" };
// Fixed wall-clock due date (America/Toronto, per the harness locale). Must
// never be relative — the Due column is rendered absolute, so a moving date
// would break the pixel baseline on every run.
export const ASSIGNMENT = { title: "Lab 1 — Warmup", dueAt: "2030-12-01T23:59" };

function extractCsrf(html) {
  let m = html.match(/name=['"]_csrf['"][^>]*\svalue=['"]([^'"]+)['"]/i);
  if (m) return m[1];
  m = html.match(/\svalue=['"]([^'"]+)['"][^>]*name=['"]_csrf['"]/i);
  if (m) return m[1];
  m = html.match(/<meta\s+name=['"]csrf-token['"]\s+content=['"]([^'"]+)['"]/i);
  if (m) return m[1];
  return null;
}

async function csrfFrom(ctx, p) {
  const res = await ctx.get(p);
  const token = extractCsrf(await res.text());
  if (!token) throw new Error(`could not find CSRF token on ${p} (status ${res.status()})`);
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
        { cell_type: "code", source: ["x = 1\n"], metadata: {}, outputs: [], execution_count: null },
      ],
    })
  );
  zip.file("test_public.py", 'print("public test ok")\n');
  return zip.generateAsync({ type: "nodebuffer" });
}

// Worker-graded on purpose: no runner is attached, so a submission stays
// "pending" forever — a deterministic results page.
const MANIFEST = JSON.stringify({
  schemaVersion: 1,
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }],
  timeLimitSeconds: 10,
  makefile: null,
});

export async function seed(baseURL) {
  const instr = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(instr, "/register");
  await expectOK(
    "register instructor",
    instr.post("/register", { form: { username: INSTRUCTOR.username, password: INSTRUCTOR.password, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]
  );

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

  // Publish the setup into an assignment and OPEN it, so the student
  // dashboard captures its populated state rather than the empty one.
  //
  // Without this the fixture left the setup unpublished: students cannot see
  // an unpublished assignment, so `student-dashboard` baselined only
  // "No assignments available yet." — leaving the populated assignment table
  // (tier-open/closed/extended chips, achievement badges, the grade override
  // tag, the submission-history cell, the icon action row) with no pixel
  // coverage on any page, in either scheme.
  //
  // Opening needs no runner: quick-publish creates the assignment with
  // validationStatus nil, and applyVisibility admits nil as well as "passed".
  csrf = await csrfFrom(instr, "/instructor");
  const publishRes = await expectOK(
    "publish assignment",
    instr.post("/instructor", {
      form: { testSetupID: setupID, title: ASSIGNMENT.title, dueAt: ASSIGNMENT.dueAt, _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [302, 303]
  );
  // Publish redirects to the editor: /instructor/<publicID>/edit
  const pubLoc = publishRes.headers()["location"] || "";
  const assignmentID = (pubLoc.match(/\/instructor\/([A-Za-z0-9_-]+)\/edit/) || [])[1];
  if (!assignmentID) throw new Error(`publish did not redirect to the editor (location: "${pubLoc}")`);

  csrf = await csrfFrom(instr, "/instructor");
  await expectOK(
    "open assignment",
    instr.post(`/instructor/${assignmentID}/status`, {
      form: { status: "open", _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [302, 303]
  );

  const instructorState = await instr.storageState();
  await instr.dispose();

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

  // One submission so the results page has something to show (stays pending —
  // no runner is attached).
  csrf = await csrfFrom(stud, `/testsetups/${setupID}/submit`);
  const subRes = await expectOK(
    "student submission",
    stud.post(`/testsetups/${setupID}/submit`, {
      multipart: {
        _csrf: csrf,
        files: {
          name: "solution.py",
          mimeType: "text/x-python",
          buffer: Buffer.from("x = 1\n"),
        },
      },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [200, 302, 303]
  );
  // The submit flow redirects to the submission page (/submissions/<id>).
  let resultsPath = null;
  const subLoc = subRes.headers()["location"] || "";
  const m = subLoc.match(/\/(submissions|results)\/[A-Za-z0-9_-]+/);
  if (m) resultsPath = m[0];
  if (!resultsPath) throw new Error(`submit did not redirect to a submission page (location: "${subLoc}")`);
  const studentState = await stud.storageState();
  await stud.dispose();

  return { setupID, assignmentID, courseID, instructorState, studentState, resultsPath };
}
