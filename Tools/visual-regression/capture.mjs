// capture.mjs — seed a running chickadee-server over its real HTTP API, then
// screenshot the key pages in BOTH colour schemes (#1136).
//
//   node capture.mjs <baseURL> <outDir>
//
// The seed flow is adapted from Tools/editor-smoke-test/notebook-page-check.mjs:
// register an instructor (first user becomes admin, and course creation seeds a
// per-course instructor enrollment), create an auto-enroll course, upload a
// worker-graded test setup, then register + log in a student (auto-enrolled on
// login) and submit once so the pending-results page renders.
//
// Determinism measures (the whole game — see docs/ui-design.md):
//   * fixed viewport / deviceScaleFactor / locale / timezone;
//   * fonts pinned to DejaVu (present in the CI image and dev containers) so
//     system-ui doesn't pick a host-specific face;
//   * animations, transitions, and carets disabled;
//   * dynamic regions (relative timestamps, version banner, canvas charts)
//     masked with a solid box via Playwright's screenshot mask.
import { chromium, request as pwRequest } from "playwright";
import JSZip from "jszip";
import fs from "node:fs";
import path from "node:path";

const baseURL = process.argv[2];
const outDir = process.argv[3];
if (!baseURL || !outDir) {
  console.error("usage: node capture.mjs <baseURL> <outDir>");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

const INSTRUCTOR = { username: "vis_instructor", password: "vis-instructor-pass-1" };
const STUDENT = { username: "vis_student", password: "vis-student-pass-1" };
const COURSE = { code: "VIS101", name: "Visual Regression 101" };

// Selectors hidden from every screenshot: content that legitimately differs
// run-to-run.  Keep this list SHORT — every mask is a blind spot.
const MASKS = [
  ".js-relative-time",     // "3 minutes ago" timestamps (relative-time.js)
  ".admin-version-banner", // vX.Y.Z on the admin page
  ".worker-secret-input",  // auto-generated diceware secret — new every boot
  "canvas",                // sparkline charts draw async
];

// ---------------------------------------------------------------------------
// Seeding over the real HTTP API (register / course / setup / student).
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

async function seed() {
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

  return { setupID, courseID, instructorState, studentState, resultsPath };
}

// ---------------------------------------------------------------------------
async function main() {
  console.log(`Seeding fixture data via ${baseURL} …`);
  const { setupID, instructorState, studentState, resultsPath } = await seed();
  console.log(`Seeded setup ${setupID}; results page: ${resultsPath || "(none)"}`);

  // page name → { path, session }.  Keep names stable: they are the baseline
  // filenames.
  const PAGES = [
    { name: "login", path: "/login", state: null },
    { name: "student-dashboard", path: "/", state: studentState },
    { name: "student-submit", path: `/testsetups/${setupID}/submit`, state: studentState },
    { name: "instructor-assignments", path: "/instructor", state: instructorState },
    { name: "admin-dashboard", path: "/admin", state: instructorState },
  ];
  if (resultsPath) {
    PAGES.push({ name: "submission-pending", path: resultsPath, state: studentState });
  }

  const browser = await chromium.launch();
  let failures = 0;
  for (const scheme of ["light", "dark"]) {
    for (const p of PAGES) {
      const context = await browser.newContext({
        baseURL,
        colorScheme: scheme,
        viewport: { width: 1280, height: 900 },
        deviceScaleFactor: 1,
        reducedMotion: "reduce",
        locale: "en-CA",
        timezoneId: "America/Toronto",
        storageState: p.state || undefined,
      });
      const page = await context.newPage();
      try {
        await page.goto(p.path, { waitUntil: "networkidle", timeout: 30_000 });
        await page.addStyleTag({
          content: `
            *, *::before, *::after {
              animation: none !important;
              transition: none !important;
              caret-color: transparent !important;
              font-family: 'DejaVu Sans', sans-serif !important;
            }
            code, pre, kbd, samp, .mono, [class*="mono"] {
              font-family: 'DejaVu Sans Mono', monospace !important;
            }
          `,
        });
        await page.waitForTimeout(300); // let post-load JS (tables, badges) settle
        const file = path.join(outDir, `${p.name}--${scheme}.png`);
        await page.screenshot({
          path: file,
          fullPage: true,
          animations: "disabled",
          mask: MASKS.map((sel) => page.locator(sel)),
          maskColor: "#FF00FF",
        });
        console.log(`captured ${p.name}--${scheme}`);
      } catch (err) {
        failures++;
        console.error(`FAILED to capture ${p.name}--${scheme}: ${err.message}`);
      } finally {
        await context.close();
      }
    }
  }
  await browser.close();
  if (failures > 0) {
    console.error(`${failures} page(s) failed to capture`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
