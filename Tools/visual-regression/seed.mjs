// seed.mjs — fixture seeding over the real HTTP API, shared by capture.mjs
// (visual regression, #1136) and a11y.mjs (accessibility scan, #1137).
// Registers an instructor (first user becomes admin), creates an auto-enroll
// course, uploads a worker-graded test setup, publishes it into an OPEN
// assignment (so the student dashboard has rows to draw), registers + logs in
// a student, and submits once (stays pending — no runner attached).
import { request as pwRequest } from "playwright";
import JSZip from "jszip";
import { createHash, createHmac, randomUUID } from "node:crypto";

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
    "test_blocked.py", "secrettest_alpha.py", "secrettest_beta.py",
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
    {
      tier: "public", script: "test_edges.py", points: 2,
      hint: "Check what your function returns for negative input.",
    },
    { tier: "public", script: "test_blocked.py", points: 2 },
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
// Shape mirrors `buildCollection` in Public/browser-runner.js. The fixture
// attaches no runner, so the seed reports the grade itself, as a runner would:
// a signed POST to /api/v1/worker/results (`postWorkerResult`).
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

// Wraps outcomes in the collection envelope `buildCollection` produces in
// Public/browser-runner.js. Fixed values only — these reach a pixel baseline.
function gradedCollection(setupID, outcomes) {
  return {
    submissionID: "",
    testSetupID: setupID,
    attemptNumber: 1,
    buildStatus: "passed",
    compilerOutput: null,
    outcomes,
    totalTests: outcomes.length,
    passCount: outcomes.filter((o) => o.status === "pass").length,
    failCount: outcomes.filter((o) => o.status === "fail").length,
    errorCount: 0,
    timeoutCount: 0,
    executionTimeMs: outcomes.reduce((sum, o) => sum + o.executionTimeMs, 0),
    runnerVersion: "browser-wasm-runner/1.0",
    timestamp: "2026-01-15T12:00:00Z",
  };
}

const GRADED_OUTCOMES = [
  gradedOutcome("test_public.py", "public", "pass", { shortResult: "4/4 cases passed" }),
  gradedOutcome("test_edges.py", "public", "fail", {
    shortResult: "2/4 cases passed",
    score: 0.5,
    longResult: "AssertionError: first_digit(-42) == 4, got -4",
  }),
  // A dependency skip, so the skipped tile and the blocked-by annotation are
  // both drawn. PUBLIC on purpose: a release row's output is redacted until the
  // deadline, which suppresses the annotation. The short result must match the
  // runner's own skip wording or the presenter will not read it as a skip.
  gradedOutcome("test_blocked.py", "public", "fail", {
    shortResult: "Skipped: prerequisite 'test_edges.py' did not pass",
  }),
  gradedOutcome("releasetest_shape.py", "release", "error", {
    shortResult: "error",
    longResult: "NameError: name 'classify' is not defined",
  }),
  gradedOutcome("secrettest_alpha.py", "secret", "pass", {
    points: 1, shortResult: "all cases passed",
  }),
  gradedOutcome("secrettest_beta.py", "secret", "fail", {
    points: 1, shortResult: "2 of 4 cases passed",
  }),
];

// A class composite (docs/class-composite.md): a 4 × 3 grid of still 4 × 4
// gray tiles, so the leaderboard draws one tile and no playback controls,
// and nothing on the captured page moves.
const COMPOSITE_MANIFEST = JSON.stringify({
  schemaVersion: 1,
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_tile.py", points: 1 }],
  timeLimitSeconds: 10,
  makefile: null,
  language: "python",
  activity: {
    kind: "classComposite",
    composite: {
      compositor: "tile",
      layout: { cols: 4, rows: 3 },
      contribution: { w: 4, h: 4, frames: 1, format: "gray8" },
      dealOrder: "rowMajor",
    },
  },
});

async function buildCompositeZip() {
  const zip = new JSZip();
  zip.file("assignment.ipynb", NOTEBOOK_JSON);
  zip.file("test_tile.py", 'print("test ok")\n');
  return zip.generateAsync({ type: "nodebuffer" });
}

// A fixed diagonal gradient, so the baseline shows the tile's pixels and its
// place in the grid.
const COMPOSITE_PIXELS = Buffer.from(
  Array.from({ length: 16 }, (_, i) => ((i % 4) + Math.floor(i / 4)) * 36)
).toString("base64");

// Uploads, publishes and opens the composite assignment. Returns its setup ID.
async function seedCompositeAssignment(instr, courseID) {
  const zipBuf = await buildCompositeZip();
  let csrf = await csrfFrom(instr, "/");
  const setupRes = await expectOK(
    "upload composite setup",
    instr.post("/api/v1/testsetups", {
      multipart: {
        manifest: COMPOSITE_MANIFEST,
        courseID,
        files: { name: "setup.zip", mimeType: "application/zip", buffer: zipBuf },
      },
      headers: { "x-csrf-token": csrf },
    }),
    [200, 201]
  );
  const setupID = JSON.parse(await setupRes.text()).testSetupID;
  if (!setupID) throw new Error("no testSetupID in composite upload response");
  csrf = await csrfFrom(instr, "/instructor");
  const publishRes = await expectOK(
    "publish composite assignment",
    instr.post("/instructor", {
      form: { testSetupID: setupID, title: "Class GPU", dueAt: ASSIGNMENT.dueAt, _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [302, 303]
  );
  const pubLoc = publishRes.headers()["location"] || "";
  const assignmentID = (pubLoc.match(/\/instructor\/([A-Za-z0-9_-]+)\/edit/) || [])[1];
  if (!assignmentID) throw new Error(`composite publish did not redirect to the editor (location: "${pubLoc}")`);
  csrf = await csrfFrom(instr, "/instructor");
  await expectOK(
    "open composite assignment",
    instr.post(`/instructor/${assignmentID}/status`, {
      form: { status: "open", _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [302, 303]
  );
  return setupID;
}

// The student opens the composite, which deals them slot 0, and posts one
// passing tile. Returns the graded submission's path.
async function seedCompositeContribution(stud, setupID, baseURL) {
  await expectOK("open composite notebook", stud.get(`/testsetups/${setupID}/notebook`), [200]);
  const outcome = {
    ...gradedOutcome("test_tile.py", "public", "pass", { points: 1, shortResult: "tile ok" }),
    composite: { w: 4, h: 4, frames: 1, format: "gray8", data: COMPOSITE_PIXELS },
  };
  // Worker-graded, like the lab: submitted through runner-submit and graded
  // by a signed runner report (see the lab's graded submissions below).
  const id = await runnerSubmit(stud, setupID, "composite submission");
  await postWorkerResult(baseURL, workerCollection(id, 1, gradedCollection(setupID, [outcome])));
  return `/submissions/${id}`;
}

// The fixture's runner secret. The run-*.sh scripts export it, so the server
// (RUNNER_SHARED_SECRET) and this seed share it.
const RUNNER_SECRET = process.env.RUNNER_SHARED_SECRET;

// Submits the notebook through runner-submit, as a worker-graded notebook
// assignment's page does. Returns the new submission's ID.
async function runnerSubmit(stud, setupID, label) {
  const csrf = await csrfFrom(stud, `/testsetups/${setupID}/submit`);
  const res = await expectOK(
    label,
    stud.post("/api/v1/submissions/runner-submit", {
      multipart: {
        testSetupID: setupID,
        filename: "assignment.ipynb",
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
  const id = JSON.parse(await res.text()).submissionID;
  if (!id) throw new Error(`no submissionID in ${label} response`);
  return id;
}

// The collection a runner reports for `submissionID`, stamped with the
// server's attempt number and the weighted grade, as browser-result used to
// reconcile them (BrowserResultRoutes.reconcileBrowserCollection).
function workerCollection(submissionID, attemptNumber, collection) {
  const outcomes = collection.outcomes.map((o) => ({
    ...o,
    attemptNumber,
    isFirstPassSuccess: attemptNumber === 1 && o.status === "pass",
  }));
  return {
    ...collection,
    submissionID,
    attemptNumber,
    outcomes,
    totalPoints: outcomes.reduce((sum, o) => sum + o.points, 0),
    earnedPoints: outcomes.reduce((sum, o) => sum + o.points * o.score, 0),
  };
}

// Posts a runner's result report, HMAC-signed as WorkerRequestSigner signs
// it (Sources/Core/WorkerHMACSigning.swift).
async function postWorkerResult(baseURL, collection) {
  if (!RUNNER_SECRET) {
    throw new Error("RUNNER_SHARED_SECRET is not set: the run script exports it for the server and the seed");
  }
  const path = "/api/v1/worker/results";
  const body = JSON.stringify({ collection, diagnostics: null });
  const bodyHash = createHash("sha256").update(body).digest("hex");
  const timestamp = String(Math.floor(Date.now() / 1000));
  const nonce = randomUUID();
  const signature = createHmac("sha256", RUNNER_SECRET)
    .update(["POST", path, bodyHash, timestamp, nonce].join("\n"))
    .digest("hex");
  const res = await fetch(new URL(path, baseURL), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-worker-timestamp": timestamp,
      "x-worker-nonce": nonce,
      "x-worker-body-sha256": bodyHash,
      "x-worker-signature": signature,
      // No x-worker-id: the middleware would record the id as an active
      // runner, and the admin dashboard baseline shows no runner.
    },
    body,
  });
  if (res.status !== 200) {
    throw new Error(`worker result for ${collection.submissionID}: status ${res.status}: ${await res.text()}`);
  }
}

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
    instr.post("/admin/courses", { form: { code: COURSE.code, name: COURSE.name, termYear: "2026", termSeason: "fall", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0 }),
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

  // Reveal tokens on, so the hidden-test block draws its reveal control. The
  // whole block is conditional on this, and an assignment without it captures a
  // materially different page.
  csrf = await csrfFrom(instr, "/instructor");
  await expectOK(
    "enable secret reveal",
    instr.post(`/instructor/${assignmentID}/secret-reveal`, {
      form: { enabled: "on", _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [200, 302, 303]
  );

  const compositeSetupID = await seedCompositeAssignment(instr, courseID);

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

  // The student's chickadee is drawn at random on first view. The bird itself
  // is masked in the capture, but the account page's picker marks the current
  // backdrop as checked, so a random draw would move that mark between runs.
  // Choose the backdrop and border through the picker route instead.
  csrf = await csrfFrom(stud, "/account");
  await expectOK(
    "student chickadee choices",
    stud.post("/account/avatar", {
      form: { backdrop: "sky", border: "none", _csrf: csrf },
      maxRedirects: 0,
    }),
    [302, 303]
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
  const collection = gradedCollection(setupID, GRADED_OUTCOMES);
  // Graded TWICE. The second attempt is what the baseline captures, because a
  // delta line ("fixed 2 tests since attempt N") only renders when a prior
  // graded attempt exists — and that line is a fourth item in the score band,
  // which is exactly the case that laid the band out wrong in production while
  // a first-attempt baseline looked fine.
  // Graded the way production grades a worker-graded notebook: the student
  // submits through runner-submit, and the grade arrives as a signed runner
  // report. The fixture used to post these through browser-result, which a
  // worker-graded assignment now refuses, because a browser-computed grade can
  // be forged (#2902, docs/grading-integrity.md D8). The values match
  // what browser-result stored (attempt numbers, points), so the baselines
  // keep their pixels.
  const firstGradedID = await runnerSubmit(stud, setupID, "first graded submission");
  await postWorkerResult(
    baseURL,
    workerCollection(
      firstGradedID,
      2,
      gradedCollection(
        setupID,
        // A worse prior attempt, so the second one reports fixes.
        GRADED_OUTCOMES.map((o) =>
          o.tier === "public" ? { ...o, status: "fail", score: 0 } : o
        )
      )
    )
  );
  const gradedID = await runnerSubmit(stud, setupID, "graded submission");
  await postWorkerResult(baseURL, workerCollection(gradedID, 3, collection));
  const gradedResultsPath = `/submissions/${gradedID}`;

  const compositeResultsPath = await seedCompositeContribution(stud, compositeSetupID, baseURL);

  // The first result page a student opens after earning a wardrobe item
  // grants it and shows the Earned toast (docs/result-celebration.md, J2).
  // The capture opens each page once per scheme, so only the first capture
  // would show the toast. The account page grants the items here instead.
  await expectOK("grant earned items", stud.get("/account"), [200]);

  const studentState = await stud.storageState();
  await stud.dispose();

  return {
    setupID, assignmentID, courseID, instructorState, studentState, resultsPath,
    gradedResultsPath, compositeSetupID, compositeResultsPath,
  };
}
