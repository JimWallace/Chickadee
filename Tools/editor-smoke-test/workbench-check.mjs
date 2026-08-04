// workbench-check.mjs
//
// END-TO-END check of the assignment workbench (`/instructor/:id/workbench`) —
// the surface that nests the JupyterLite editor one frame deeper than anything
// before it.
//
// This exists because that nesting introduced a failure mode no unit test can
// see. Cross-origin isolation is a property of the ENTIRE ancestor chain, so
// the workbench shell and its left pane must both carry COOP/COEP or:
//
//   * `crossOriginIsolated` goes false inside the notebook iframe, the kernel
//     silently drops off SharedArrayBuffer onto the service-worker comlink
//     transport, and NOTHING reports an error — the editor still boots, just
//     on the path the codebase deliberately moved away from; or
//   * under `require-corp` the browser refuses the left pane outright
//     (ERR_BLOCKED_BY_RESPONSE.CoepFrameResourceNeedsCoepHeader) and the author
//     gets an empty pane where the editor should be.
//
// COEPMiddlewareTests pins the *headers*. Only a real browser can confirm the
// isolation those headers are supposed to produce actually survives two levels
// of framing, which is what this check does. It is the automated form of what
// was otherwise a manual "open DevTools in the nested iframe" step.
//
// Asserts, as the instructor who authors the assignment:
//
//   1. the workbench shell is cross-origin isolated (chromium/firefox);
//   2. the LEFT pane loaded a real edit page — i.e. was not COEP-refused;
//   3. the NESTED notebook iframe is cross-origin isolated and has
//      SharedArrayBuffer — the property the whole chain exists to preserve;
//   4. the notebook pane mounts the assignment notebook and leaves the solution
//      pane unmounted until asked (the lazy-mount contract that keeps a second
//      Pyodide off the page until an author actually wants it).
//
// WebKit is expected NON-isolated at every level — it needs the comlink path —
// so there the assertion is inverted, exactly as in notebook-page-check.mjs.
//
// Usage:   node workbench-check.mjs <baseURL>
// Exit 0 = healthy; exit 1 = broken (details printed).

import { chromium, webkit, firefox } from "playwright";
import { request as pwRequest } from "playwright";
import JSZip from "jszip";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;

const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");

const STAMP = Date.now().toString(36);
const INSTRUCTOR = { username: `e2e_wb_instr_${STAMP}`, password: "instructor-pw-123" };
const COURSE = { code: `WB${STAMP}`.slice(0, 12), name: "E2E Workbench Course" };

const PAGE_LOAD_MS = 30_000;
// The shell loads two documents, one of which boots a Pyodide kernel. We do not
// wait for the kernel here — notebook-page-check.mjs already proves kernels boot
// — but the frames themselves have to settle.
const FRAME_SETTLE_MS = parseInt(process.env.SMOKE_FRAME_MS || "60000", 10);

function fail(reason, extra) {
  console.log(`E2E FAIL — ${reason}`);
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
        { cell_type: "code", source: ["x = 1\n"], metadata: {}, outputs: [], execution_count: null },
      ],
    })
  );
  zip.file("test_public.py", 'print("public test ok")\n');
  return zip.generateAsync({ type: "nodebuffer" });
}

const MANIFEST = JSON.stringify({
  schemaVersion: 1,
  gradingMode: "browser",
  requiredFiles: [],
  testSuites: [{ tier: "public", script: "test_public.py" }],
  timeLimitSeconds: 10,
  makefile: null,
});

// --- Seed via the real HTTP API ------------------------------------------
//
// Unlike notebook-page-check.mjs we stay signed in as the INSTRUCTOR: the
// workbench is staff-only, and it is the authoring surface, so the instructor
// session is the one under test. We also have to publish an assignment — the
// workbench keys off the assignment's public ID, not the bare test setup.
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

  // Publish the assignment; the redirect carries its public ID.
  csrf = await csrfFrom(instr, "/instructor");
  const pubRes = await expectOK(
    "publish assignment",
    instr.post("/instructor", {
      form: { testSetupID: setupID, title: "Workbench E2E Lab", _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [302, 303]
  );
  const pubLoc = pubRes.headers()["location"] || "";
  const assignmentID = (pubLoc.match(/\/instructor\/([^/]+)\/edit/) || [])[1];
  if (!assignmentID) throw new Error(`could not parse assignmentID from redirect: "${pubLoc}"`);

  const storageState = await instr.storageState();
  await instr.dispose();
  return { setupID, assignmentID, storageState };
}

/// Read `crossOriginIsolated` inside a specific frame, by URL substring.
///
/// A missing frame is itself a diagnosis, and the most likely one: when a
/// document is refused under `require-corp` the navigation never commits, so
/// the iframe is still sitting on about:blank rather than holding an error
/// page. Verified by removing the panel's COEP match and watching this fire.
async function isolationOf(page, urlPart, label) {
  const frame = page.frames().find((f) => f.url().includes(urlPart));
  if (!frame) {
    const seen = page.frames().map((f) => f.url() || "(blank)").join("\n  ");
    throw new Error(
      `${label}: no frame ever committed "${urlPart}". The usual cause is that ` +
      `the browser refused the document under COEP require-corp ` +
      `(ERR_BLOCKED_BY_RESPONSE.CoepFrameResourceNeedsCoepHeader) because it ` +
      `did not send require-corp itself — check COEPMiddleware.needsCOEP.\n` +
      `Frames seen:\n  ${seen}`
    );
  }
  return frame.evaluate(() => ({
    isolated: globalThis.crossOriginIsolated === true,
    sab: typeof SharedArrayBuffer === "function",
    // A COEP-refused document is replaced by an error page, which has no body
    // text from our template. Length is a cheap proxy for "real document".
    bodyLen: (document.body && document.body.textContent || "").length,
  }));
}

async function main() {
  console.log(`Browser engine: ${browserName}`);
  // WebKit deadlocks on the SharedArrayBuffer kernel transport, so it is served
  // NON-isolated on purpose — at every level of the chain, consistently.
  const expectIsolated = browserName !== "webkit";
  console.log(`Expecting cross-origin isolation = ${expectIsolated}`);

  let seeded;
  try {
    seeded = await seed();
  } catch (e) {
    return fail(`seeding failed: ${(e && e.message) || e}`);
  }

  const workbenchURL = `${baseURL}/instructor/${seeded.assignmentID}/workbench`;
  console.log(`Seeded assignment ${seeded.assignmentID}; opening ${workbenchURL}`);

  const launchOptions =
    browserName === "chromium"
      ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false }
      : { headless: true };
  // Escape hatch for running this locally against a pre-installed browser whose
  // build number does not match the pinned Playwright's expectation. CI installs
  // the matching build and leaves this unset.
  if (process.env.SMOKE_BROWSER_PATH) {
    launchOptions.executablePath = process.env.SMOKE_BROWSER_PATH;
  }
  const browser = await browserType.launch(launchOptions);
  const context = await browser.newContext({ storageState: seeded.storageState });
  const page = await context.newPage();

  const consoleErrors = [];
  page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });

  try {
    const res = await page.goto(workbenchURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });
    if (!res || !res.ok()) {
      return fail(`workbench page did not load (status ${res && res.status()})`);
    }

    // 1. The shell itself.
    const shellIsolated = await page.evaluate(() => globalThis.crossOriginIsolated === true);
    console.log(`shell crossOriginIsolated = ${shellIsolated}`);
    if (shellIsolated !== expectIsolated) {
      return fail(
        `workbench shell isolation is ${shellIsolated}, expected ${expectIsolated}. ` +
        `COEPMiddleware.needsCOEP is not matching /instructor/:id/workbench.`
      );
    }

    // Give both panes a chance to commit their navigations.
    await page.waitForFunction(
      () => {
        const l = document.getElementById("wb-edit-frame");
        const n = document.getElementById("wb-notebook-assignment");
        return l && n && l.contentWindow && n.contentWindow;
      },
      { timeout: FRAME_SETTLE_MS }
    );
    await page.waitForTimeout(2000);

    // 2. The left pane must be a REAL edit page. If COEP refused it, the frame
    //    exists but holds a browser error document.
    const left = await isolationOf(page, "/workbench/panel", "left pane");
    console.log(`left pane: isolated=${left.isolated} bodyLen=${left.bodyLen}`);
    if (left.bodyLen < 100) {
      return fail(
        "the left pane is empty — the edit page was almost certainly refused by COEP " +
        "(ERR_BLOCKED_BY_RESPONSE.CoepFrameResourceNeedsCoepHeader). " +
        "/instructor/:id/workbench/panel needs the same isolation headers as the shell."
      );
    }
    const leftHasEditor = await page
      .frames()
      .find((f) => f.url().includes("/workbench/panel"))
      .evaluate(() => !!document.getElementById("suite-sections"));
    if (!leftHasEditor) {
      return fail("the left pane loaded but is not the assignment editor (no #suite-sections)");
    }

    // 3. The nested notebook page — the reason this check exists.
    const nb = await isolationOf(page, "/notebook", "notebook pane");
    console.log(`notebook pane: isolated=${nb.isolated} SharedArrayBuffer=${nb.sab}`);
    if (nb.isolated !== expectIsolated) {
      return fail(
        `NESTED notebook pane isolation is ${nb.isolated}, expected ${expectIsolated}. ` +
        `This is the silent failure: the kernel still boots, but on the ` +
        `service-worker comlink transport instead of SharedArrayBuffer.`
      );
    }
    if (expectIsolated && !nb.sab) {
      return fail("nested notebook pane is isolated but has no SharedArrayBuffer");
    }

    // 4. Lazy mount: the assignment notebook is mounted, the solution is not.
    const mounts = await page.evaluate(() => {
      const a = document.getElementById("wb-notebook-assignment");
      const s = document.getElementById("wb-notebook-solution");
      return {
        assignment: a ? a.getAttribute("src") : null,
        solutionPresent: !!s,
        solution: s ? s.getAttribute("src") : null,
      };
    });
    console.log(`mounts: assignment=${mounts.assignment} solution=${mounts.solution}`);
    if (!mounts.assignment || !mounts.assignment.includes("file=assignment")) {
      return fail(`assignment notebook pane is not mounted (src=${mounts.assignment})`);
    }
    if (mounts.solutionPresent && mounts.solution !== "about:blank") {
      return fail(
        `solution pane mounted eagerly (src=${mounts.solution}); it must stay at ` +
        `about:blank until its tab is selected, so a second Pyodide is only paid ` +
        `for by an author who asks for it.`
      );
    }

    console.log("E2E OK — workbench isolation chain intact, panes wired as designed.");
    process.exit(0);
  } catch (e) {
    return fail(`workbench check threw: ${(e && e.message) || e}`, consoleErrors.join("\n"));
  } finally {
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

main().catch((e) => fail(`unexpected: ${(e && e.stack) || e}`));
