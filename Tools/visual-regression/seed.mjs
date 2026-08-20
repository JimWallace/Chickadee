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

const NOTEBOOK_JSON = JSON.stringify({
  nbformat: 4,
  nbformat_minor: 5,
  metadata: { kernelspec: { name: "python", display_name: "Python" } },
  cells: [
    { cell_type: "code", source: ["x = 1\n"], metadata: {}, outputs: [], execution_count: null },
  ],
});

async function buildSetupZip() {
  const zip = new JSZip();
  zip.file("assignment.ipynb", NOTEBOOK_JSON);
  for (const name of [
    "test_public.py", "test_edges.py", "releasetest_shape.py",
    "secrettest_alpha.py", "secrettest_beta.py",
  ]) {
    zip.file(name, 'print("test ok")\n');
  }
  return zip.generateAsync({ type: "nodebuffer" });
}

// Worker-graded on purpose: no runner is attached, so a submission stays
// "pending" forever — a deterministic results page.
const MANIFEST = JSON.stringify({
  schemaVersion: 1,
  requiredFiles: [],
  // Weighted and multi-tier on purpose: the graded results page renders points
  // labels only when the assignment is weighted, and the masked hidden-test
  // block only when secret tests exist. A single unweighted public test draws
  // none of it.
  testSuites: [
    { tier: "public", script: "test_public.py", points: 2 },
    { tier: "public", script: "test_edges.py", points: 2 },
    { tier: "release", script: "releasetest_shape.py", points: 2 },
    { tier: "secret", script: "secrettest_alpha.py", points: 1 },
    { tier: "secret", script: "secrettest_beta.py", points: 1 },
  ],
  timeLimitSeconds: 10,
  makefile: null,
});

// The graded fixture result. Fixed values throughout — every number and string
// here lands in a pixel baseline, so nothing may derive from the clock, the
// run, or the machine.
//
// Shape mirrors `buildCollection` in Public/browser-runner.js: the browser
// grader posts exactly this to /api/v1/submissions/browser-result, which is a
// real production path and needs no runner and no HMAC secret. That is the
// whole reason the graded page can be captured at all — the fixture attaches
// no runner, so a worker-graded submission stays pending forever.
function gradedOutcome(name, tier, status, opts = {}) {
  return {
    testName: name,
    testClass: null,
    tier,
    status,
    shortResult: opts.shortResult ?? (status === "pass" ? "ok" : "1 case failed"),
    longResult: opts.longResult ?? null,
    score: opts.score ?? (status === "pass" ? 1 : 0),
    points: opts.points ?? 2,
    executionTimeMs: opts.executionTimeMs ?? 12,
    memoryUsageBytes: null,
    attemptNumber: 1,
    isFirstPassSuccess: false,
  };
}

const GRADED_OUTCOMES = [
  gradedOutcome("test_public.py", "public", "pass", { shortResult: "4/4 cases passed" }),
  gradedOutcome("test_edges.py", "public", "fail", {
    shortResult: "2/4 cases passed",
    score: 0.5,
    longResult: "AssertionError: first_digit(-42) == 4, got -4",
  }),
  gradedOutcome("releasetest_shape.py", "release", "pass", { shortResult: "ok" }),
  gradedOutcome("secrettest_alpha.py", "secret", "pass", { points: 1 }),
  gradedOutcome("secrettest_beta.py", "secret", "fail", { points: 1 }),
];

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
  // A SECOND submission, graded, so the results page has a captured state that
  // is not the pending spinner. The first one stays pending on purpose — that
  // is what `submission-pending` baselines.
  const collection = {
    submissionID: "",
    testSetupID: setupID,
    attemptNumber: 1,
    buildStatus: "passed",
    compilerOutput: null,
    outcomes: GRADED_OUTCOMES,
    totalTests: GRADED_OUTCOMES.length,
    passCount: GRADED_OUTCOMES.filter((o) => o.status === "pass").length,
    failCount: GRADED_OUTCOMES.filter((o) => o.status === "fail").length,
    errorCount: 0,
    timeoutCount: 0,
    executionTimeMs: GRADED_OUTCOMES.reduce((sum, o) => sum + o.executionTimeMs, 0),
    runnerVersion: "browser-wasm-runner/1.0",
    // Fixed, not `new Date()`: this reaches a pixel baseline.
    timestamp: "2026-01-15T12:00:00Z",
  };
  csrf = await csrfFrom(stud, `/testsetups/${setupID}/submit`);
  const gradedRes = await expectOK(
    "graded browser submission",
    stud.post("/api/v1/submissions/browser-result", {
      multipart: {
        collection: JSON.stringify(collection),
        testSetupID: setupID,
        notebook: {
          name: "assignment.ipynb",
          mimeType: "application/octet-stream",
          buffer: Buffer.from(NOTEBOOK_JSON),
        },
      },
      headers: { "x-csrf-token": csrf },
    }),
    [200, 201]
  );
  const gradedID = JSON.parse(await gradedRes.text()).submissionID;
  if (!gradedID) throw new Error("no submissionID in browser-result response");
  const gradedResultsPath = `/submissions/${gradedID}`;

  const studentState = await stud.storageState();
  await stud.dispose();

  return {
    setupID, assignmentID, courseID, instructorState, studentState, resultsPath,
    gradedResultsPath,
  };
}
