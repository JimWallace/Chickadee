// seed.mjs — seed one browser-graded assignment and a logged-in student over
// the real HTTP API, for a probe that drives the real notebook page.
//
// register instructor (the first user is admin) → create a course → make it
// auto-enroll → upload a test setup → register and log in a student. Returns
// the setup id and the student's Playwright storage state.
//
// The same sequence as notebook-page-check.mjs, which keeps its own copy.
// `seedInstructorAssignment` stops at the instructor instead: it publishes the
// assignment, gives it a solution, and returns the instructor's session, for a
// probe of the workbench. Its `nonAdmin` option makes that instructor a
// non-admin course instructor.

import { request as pwRequest } from "playwright";
import JSZip from "jszip";

function extractCsrf(html) {
  let m = html.match(/name=['"]_csrf['"][^>]*\svalue=['"]([^'"]+)['"]/i);
  if (m) return m[1];
  m = html.match(/\svalue=['"]([^'"]+)['"][^>]*name=['"]_csrf['"]/i);
  if (m) return m[1];
  m = html.match(/<meta\s+name=['"]csrf-token['"]\s+content=['"]([^'"]+)['"]/i);
  return m ? m[1] : null;
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

/// Seeds the assignment. `notebook` is the starter notebook object, `files`
/// maps the other zip entries to their text, and `manifest` is the manifest
/// object.
export async function seedAssignment(baseURL, { notebook, files, manifest }) {
  const stamp = Date.now().toString(36);
  const instructor = { username: `e2e_instr_${stamp}`, password: "instructor-pw-123" };
  const student = { username: `e2e_student_${stamp}`, password: "student-pw-123" };
  const course = { code: `E2E${stamp}`.slice(0, 12), name: "E2E Browser Course" };

  const instr = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(instr, "/register");
  await expectOK(
    "register instructor",
    instr.post("/register", { form: { ...instructor, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  csrf = await csrfFrom(instr, "/admin/courses/new");
  const courseRes = await expectOK(
    "create course",
    instr.post("/admin/courses", {
      form: { code: course.code, name: course.name, termYear: "2026", termSeason: "fall", _csrf: csrf },
      headers: { "x-csrf-token": csrf }, maxRedirects: 0,
    }),
    [302, 303]);
  const loc = courseRes.headers()["location"] || "";
  const courseID = (loc.match(/\/admin\/courses\/([0-9a-fA-F-]{36})/) || [])[1];
  if (!courseID) throw new Error(`could not parse courseID from redirect: "${loc}"`);
  await expectOK(
    "set enrollment auto",
    instr.post(`/courses/${courseID}/enrollment-mode`, {
      form: { enrollmentMode: "auto", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0,
    }),
    [302, 303]);

  const zip = new JSZip();
  zip.file("assignment.ipynb", JSON.stringify(notebook));
  for (const [name, text] of Object.entries(files)) zip.file(name, text);
  const zipBuf = await zip.generateAsync({ type: "nodebuffer" });
  csrf = await csrfFrom(instr, "/");
  const setupRes = await expectOK(
    "upload test setup",
    instr.post("/api/v1/testsetups", {
      multipart: {
        manifest: JSON.stringify(manifest),
        courseID,
        files: { name: "setup.zip", mimeType: "application/zip", buffer: zipBuf },
      },
      headers: { "x-csrf-token": csrf },
    }),
    [200, 201]);
  const setupID = JSON.parse(await setupRes.text()).testSetupID;
  if (!setupID) throw new Error("no testSetupID in upload response");
  await instr.dispose();

  const stud = await pwRequest.newContext({ baseURL });
  csrf = await csrfFrom(stud, "/register");
  await expectOK(
    "register student",
    stud.post("/register", { form: { ...student, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  csrf = await csrfFrom(stud, "/login");
  await expectOK(
    "login student",
    stud.post("/login", { form: { ...student, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  const storageState = await stud.storageState();
  await stud.dispose();
  return { setupID, courseID, storageState };
}

/// Registers an account and signs it in. Returns the request context, which
/// holds its session.
async function registerAndLogin(baseURL, account, label) {
  const ctx = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(ctx, "/register");
  await expectOK(
    `register ${label}`,
    ctx.post("/register", { form: { ...account, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  csrf = await csrfFrom(ctx, "/login");
  await expectOK(
    `login ${label}`,
    ctx.post("/login", { form: { ...account, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  return ctx;
}

/// Seeds an assignment for the instructor who authors it: the same course and
/// test setup as `seedAssignment`, then a published assignment with a
/// reference solution. Returns its public id and the instructor's Playwright
/// storage state.
///
/// By default the instructor is the first account, so an admin. With
/// `nonAdmin: true`, a throwaway admin (the first account) creates the course
/// and adds the instructor, a second account whose deployment role is `user`,
/// as course `instructor`; the instructor then authors everything else. An
/// admin passes checks that course staff do not (listing `users` on the server
/// drive answered non-admin staff 403, and the WebKit kernel never reached
/// idle, 2026-11), so a probe of a staff page should run as a non-admin.
export async function seedInstructorAssignment(baseURL, { notebook, files, manifest, title, nonAdmin = false }) {
  const stamp = Date.now().toString(36);
  const instructor = { username: `e2e_wbi_${stamp}`, password: "instructor-pw-123" };
  const course = { code: `WBI${stamp}`.slice(0, 12), name: "E2E Workbench Course" };

  let instr;
  let creator;
  if (nonAdmin) {
    creator = await registerAndLogin(baseURL, { username: `e2e_adm_${stamp}`, password: "admin-pw-123" }, "admin");
  } else {
    instr = await pwRequest.newContext({ baseURL });
    const regCsrf = await csrfFrom(instr, "/register");
    await expectOK(
      "register instructor",
      instr.post("/register", { form: { ...instructor, _csrf: regCsrf }, maxRedirects: 0 }),
      [200, 302, 303]);
    creator = instr;
  }

  let csrf = await csrfFrom(creator, "/admin/courses/new");
  const courseRes = await expectOK(
    "create course",
    creator.post("/admin/courses", {
      form: { code: course.code, name: course.name, termYear: "2026", termSeason: "fall", _csrf: csrf },
      headers: { "x-csrf-token": csrf }, maxRedirects: 0,
    }),
    [302, 303]);
  const courseID = ((courseRes.headers()["location"] || "").match(/\/admin\/courses\/([0-9a-fA-F-]{36})/) || [])[1];
  if (!courseID) throw new Error("could not parse courseID from the redirect");

  if (nonAdmin) {
    instr = await registerAndLogin(baseURL, instructor, "instructor");
    csrf = await csrfFrom(creator, `/admin/courses/${courseID}`);
    const staffRes = await expectOK(
      "add instructor as course staff",
      creator.post(`/admin/courses/${courseID}/staff`, {
        form: { identifier: instructor.username, role: "instructor", _csrf: csrf },
        headers: { "x-csrf-token": csrf }, maxRedirects: 0,
      }),
      [302, 303]);
    const staffLoc = staffRes.headers()["location"] || "";
    if (!staffLoc.includes("staffAdded=1")) throw new Error(`adding the instructor as staff failed: "${staffLoc}"`);
    await creator.dispose();
    // The instructor's session predates the enrollment; sign in again so no
    // per-session course or role state is stale.
    csrf = await csrfFrom(instr, "/login");
    await expectOK(
      "login instructor",
      instr.post("/login", { form: { ...instructor, _csrf: csrf }, maxRedirects: 0 }),
      [200, 302, 303]);
    const adminPage = await instr.get("/admin", { maxRedirects: 0 });
    if (adminPage.status() === 200) {
      throw new Error("the instructor opened /admin: the seeded account is an admin, not course staff");
    }
  }

  csrf = await csrfFrom(instr, "/");
  await expectOK(
    "set enrollment auto",
    instr.post(`/courses/${courseID}/enrollment-mode`, {
      form: { enrollmentMode: "auto", _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0,
    }),
    [302, 303]);

  const zip = new JSZip();
  zip.file("assignment.ipynb", JSON.stringify(notebook));
  for (const [name, text] of Object.entries(files)) zip.file(name, text);
  const zipBuf = await zip.generateAsync({ type: "nodebuffer" });
  csrf = await csrfFrom(instr, "/");
  const setupRes = await expectOK(
    "upload test setup",
    instr.post("/api/v1/testsetups", {
      multipart: {
        manifest: JSON.stringify(manifest), courseID,
        files: { name: "setup.zip", mimeType: "application/zip", buffer: zipBuf },
      },
      headers: { "x-csrf-token": csrf },
    }),
    [200, 201]);
  const setupID = JSON.parse(await setupRes.text()).testSetupID;

  csrf = await csrfFrom(instr, "/instructor");
  const pubRes = await expectOK(
    "publish assignment",
    instr.post("/instructor", {
      form: { testSetupID: setupID, title, _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0,
    }),
    [302, 303]);
  const assignmentID = ((pubRes.headers()["location"] || "").match(/\/instructor\/([^/]+)\/edit/) || [])[1];
  if (!assignmentID) throw new Error("could not parse assignmentID from the redirect");

  csrf = await csrfFrom(instr, `/instructor/${assignmentID}/edit`);
  await expectOK(
    "create solution",
    instr.post(`/instructor/${assignmentID}/create-solution`, {
      form: { _csrf: csrf }, headers: { "x-csrf-token": csrf }, maxRedirects: 0,
    }),
    [302, 303]);

  const storageState = await instr.storageState();
  await instr.dispose();
  return { setupID, assignmentID, storageState };
}

/// Registers a student and signs them in once, so the auto-enrolling course
/// that `seedInstructorAssignment` made enrolls them. Returns their username.
export async function registerStudent(baseURL) {
  const student = { username: `e2e_pv_${Date.now().toString(36)}`, password: "student-pw-123" };
  const stud = await pwRequest.newContext({ baseURL });
  let csrf = await csrfFrom(stud, "/register");
  await expectOK(
    "register student",
    stud.post("/register", { form: { ...student, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  csrf = await csrfFrom(stud, "/login");
  await expectOK(
    "login student",
    stud.post("/login", { form: { ...student, _csrf: csrf }, maxRedirects: 0 }),
    [200, 302, 303]);
  await stud.dispose();
  return student.username;
}
