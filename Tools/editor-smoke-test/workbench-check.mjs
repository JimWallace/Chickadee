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
//   4. there is exactly ONE notebook iframe — the tabs and the view switch
//      repoint it rather than each owning a live document, so there is one
//      Pyodide kernel however many notebooks the assignment has;
//   5. a keystroke in a pane reaches the shell as `chickadee:activity`, the
//      chain that stops the idle watchdog signing an author out mid-edit;
//   6. the view switch appears on a notebook that carries placeholders and
//      repoints to `view=template`, and the tabs repoint to the other file;
//   7. a write from the pane (creating a suite section) leaves the pane on the
//      panel URL rather than following the handler's redirect into the chromed
//      standalone editor, and does not disturb the notebook document.
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
        // A personalization placeholder, deliberately: without one the server
        // reports no template view, the switch is (correctly) not rendered, and
        // the assertion below would be skipped — passing while testing nothing.
        //
        // It must be a CODE cell. `NotebookSubstitution.placeholderNames(in:)`
        // scans `cell_type == "code"` only, so a `{{name}}` in markdown is
        // invisible to the whole personalization pipeline.
        {
          cell_type: "code",
          source: ["dataset_name = '{{dataset_name}}'\n"],
          metadata: {},
          outputs: [],
          execution_count: null,
        },
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

  // Give the assignment a reference solution, so the workbench actually renders
  // the Solution tab and the switching assertions are live rather than skipped.
  // This is the same button the edit page's Files table offers.
  csrf = await csrfFrom(instr, `/instructor/${assignmentID}/edit`);
  await expectOK(
    "create solution",
    instr.post(`/instructor/${assignmentID}/create-solution`, {
      form: { _csrf: csrf },
      headers: { "x-csrf-token": csrf },
      maxRedirects: 0,
    }),
    [302, 303]
  );

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

    // Give the editor iframe a chance to commit its navigation.  It is the
    // only frame left: #1266 merged both halves into this document, so the
    // wrapper frames the old waits keyed on no longer exist.
    await page.waitForFunction(
      () => {
        const f = document.getElementById("jl-frame");
        return f && f.contentWindow;
      },
      { timeout: FRAME_SETTLE_MS }
    );
    await page.waitForTimeout(2000);

    // 2. Both halves are in THIS document — no wrapper frames.
    const halves = await page.evaluate(() => ({
      hasEditor: !!document.getElementById("suite-sections"),
      hasFiles: !!document.getElementById("notebook-files-table"),
      hasNotebook: !!document.getElementById("jl-frame"),
      iframes: document.querySelectorAll("iframe").length,
      wrapperFrames: document.querySelectorAll("#wb-edit-frame, #wb-notebook").length,
    }));
    console.log(
      `merged doc: editor=${halves.hasEditor} files=${halves.hasFiles} ` +
      `notebook=${halves.hasNotebook} iframes=${halves.iframes}`
    );
    if (!halves.hasEditor || !halves.hasFiles) {
      return fail("the edit half is not in the workbench document (no #suite-sections)");
    }
    if (!halves.hasNotebook) {
      return fail("the notebook half is not in the workbench document (no #jl-frame)");
    }
    if (halves.wrapperFrames !== 0) {
      return fail(
        `found ${halves.wrapperFrames} wrapper iframe(s). #1266 removed them; a ` +
        `reintroduced one means a write can navigate a pane out from under the author.`
      );
    }

    // 3. Exactly ONE iframe, and it is the editor.
    //
    //    Counted rather than name-checked: each live notebook document holds a
    //    Pyodide kernel, so an iframe per destination is a kernel per
    //    destination. This also proves the merge actually happened rather than
    //    the panes simply being renamed.
    if (halves.iframes !== 1) {
      return fail(
        `expected exactly one iframe (the JupyterLite editor), found ${halves.iframes}.`
      );
    }

    // 4. The editor iframe is cross-origin isolated — the reason this check
    //    exists. The merge removed a link in the ancestor chain, so re-prove it
    //    rather than assuming it got easier.
    const nb = await isolationOf(page, "/jupyterlite/", "editor frame");
    console.log(`editor frame: isolated=${nb.isolated} SharedArrayBuffer=${nb.sab}`);
    if (nb.isolated !== expectIsolated) {
      return fail(
        `editor frame isolation is ${nb.isolated}, expected ${expectIsolated}. ` +
        `This is the silent failure: the kernel still boots, but on the ` +
        `service-worker comlink transport instead of SharedArrayBuffer.`
      );
    }
    if (expectIsolated && !nb.sab) {
      return fail("editor frame is isolated but has no SharedArrayBuffer");
    }

    // 5. Idle-logout needs no forwarder any more.
    //
    //    `idle-logout.js` measures interaction with its OWN document. That used
    //    to be the shell while every keystroke landed in a pane, so an author
    //    could be signed out mid-edit unless `embedded-activity.js` forwarded
    //    activity up. One document means the watchdog and the keystrokes are
    //    the same document, so assert the forwarder is *gone* and the watchdog
    //    is present to see events directly.
    const idle = await page.evaluate(() => ({
      hasIdleLogout: !!document.querySelector('script[src*="idle-logout.js"]'),
      hasForwarder: !!document.querySelector('script[src*="embedded-activity.js"]'),
    }));
    console.log(`idle-logout=${idle.hasIdleLogout} forwarder=${idle.hasForwarder}`);
    if (!idle.hasIdleLogout) {
      return fail("idle-logout.js is not loaded — an author will not be signed out at all");
    }
    if (idle.hasForwarder) {
      return fail("embedded-activity.js is still loaded; #1266 deleted it");
    }

    // 6a. The view switch, asserted while the ASSIGNMENT is selected.
    //
    //     Order matters and cost me a run: the seeded solution has no
    //     placeholders, so checking this after selecting Solution finds the
    //     control correctly hidden and proves nothing. The seeded assignment
    //     carries `{{dataset_name}}` precisely so this path is live.
    const viewSwitchVisible = await page.evaluate(() => {
      const v = document.getElementById("wb-viewswitch");
      return {
        present: !!v,
        visible: !!v && !v.hidden,
        flag: v ? v.getAttribute("data-assignment-has-template") : null,
      };
    });
    console.log(
      `view switch: present=${viewSwitchVisible.present} visible=${viewSwitchVisible.visible} ` +
      `assignmentHasTemplate=${viewSwitchVisible.flag}`);
    if (!viewSwitchVisible.visible) {
      return fail(
        "the view switch is not showing on an assignment whose notebook carries " +
        "{{dataset_name}}. Either the server did not detect the placeholder " +
        "(assignmentHasTemplateView) or workbench.js is not un-hiding the control."
      );
    }
    await page.click('#wb-viewswitch .wb-view[data-wb-view="template"]');
    await page.waitForNavigation({ waitUntil: "domcontentloaded", timeout: FRAME_SETTLE_MS })
      .catch(() => {});
    await page.waitForTimeout(1000);
    const afterView = { url: page.url() };
    console.log(`after view switch: url=${afterView.url}`);
    // A navigation of THIS page now, not a repointed iframe: switching views
    // reboots the kernel either way, so it is an ordinary navigation to the
    // same route with different arguments — and the edit half comes back
    // consistent with what the notebook shows.
    if (!afterView.url.includes("view=template")) {
      return fail(`the view switch did not navigate to the template (url=${afterView.url})`);
    }
    if (!afterView.url.includes("/workbench")) {
      return fail(
        `the view switch left the workbench entirely (url=${afterView.url}). It must ` +
        `stay on this route — landing on the bare notebook page loses the edit half.`);
    }

    // 6b. The Files table drives which notebook is open.
    //
    //     Two things are asserted, and the second is the one that was a live
    //     bug: those Edit links used to be able to navigate the LEFT pane into
    //     a fully-chromed notebook page, and the assignment editor vanished.
    const hasSolutionEdit = await page.evaluate(
      () => !!document.getElementById("solution-notebook-edit-btn"));
    // Asserted, not assumed: the seed creates a solution, so a missing button
    // means the wiring or the seed broke — not that this case does not apply.
    if (!hasSolutionEdit) {
      return fail(
        "the Files table has no solution Edit button, so the switching assertion " +
        "below would silently skip. The seed creates a solution.");
    }
    {
      await page.click("#solution-notebook-edit-btn");
      await page.waitForNavigation({ waitUntil: "domcontentloaded", timeout: FRAME_SETTLE_MS })
        .catch(() => {});
      await page.waitForTimeout(1200);

      const afterOpen = { url: page.url() };
      console.log(`after Files-table open: url=${afterOpen.url}`);
      if (!afterOpen.url.includes("file=solution")) {
        return fail(
          `clicking the Files table's solution Edit did not open the solution ` +
          `(url=${afterOpen.url})`);
      }

      // Still the workbench, with both halves — the failure mode being guarded
      // against is landing on a bare notebook page with no editor.
      const stillMerged = await page.evaluate(() => ({
        editor: !!document.getElementById("suite-sections"),
        notebook: !!document.getElementById("jl-frame"),
      }));
      if (!stillMerged.editor) {
        return fail(
          "the edit half is gone after opening the solution — the Edit link " +
          "navigated off the workbench instead of switching which notebook is open.");
      }

      // Rendering the markup is not the same as loading the document, and the
      // difference is not cosmetic: an assertion here once passed for a build
      // where the solution notebook 404'd and the frame held a
      // `chrome-error://` page. The author saw an error where the editor should
      // be and the check said OK.
      if (!stillMerged.notebook) {
        return fail(
          "the solution opened but there is no editor iframe — the notebook body " +
          "did not render (a missing solution degrades to the no-notebook pane).",
          page.frames().map((f) => f.url() || "(blank)").join("\n  "));
      }
      const editorCommitted = page
        .frames()
        .some((f) => (f.url() || "").includes("/jupyterlite/"));
      if (!editorCommitted) {
        return fail(
          "no JupyterLite document committed in the editor frame after switching to " +
          "the solution — the frame is sitting on about:blank or an error page.",
          page.frames().map((f) => f.url() || "(blank)").join("\n  "));
      }
    }

    // 7. A write keeps the page — and keeps the kernel alive.
    //
    //    Every write on the edit half answers with a redirect to
    //    `/instructor/:id/edit`, the fully-chromed standalone editor. Following
    //    it used to land IN THE LEFT PANE: the author added a suite section and
    //    the editor was replaced by a second copy of itself, nav bar and all.
    //
    //    Merged (#1266) the stakes are higher, and this is the assertion that
    //    carries them. The edit form and a live Pyodide kernel now share ONE
    //    document, so a navigation — or a `location.reload()` in the refresh
    //    path — tears the kernel down and takes the author's unsaved cells with
    //    it. The probe below was written before the merge precisely so the merge
    //    would inherit a test that already knew what it must not break.
    {
      // Marked from inside the frame, via Playwright, rather than by reaching
      // through `contentWindow`: the page cannot touch the editor frame's window
      // (the browser reports it cross-origin under the isolation headers this
      // page depends on, even though both documents are same-origin). Playwright
      // evaluates per-frame and is not subject to that, and a Frame handle
      // survives navigation — which is precisely what makes it a
      // document-identity probe. If the document is replaced, the property is
      // gone from the new one.
      const editorFrame = page.frames().find((f) => (f.url() || "").includes("/jupyterlite/"));
      if (!editorFrame) {
        return fail(
          "no editor frame to probe — the workbench is not showing a notebook.",
          page.frames().map((f) => f.url() || "(blank)").join("\n  "));
      }
      await editorFrame.evaluate(() => { window.__ckWorkbenchProbe = "alive"; });
      // Read it back before relying on it. An unsettable probe would make the
      // survival assertion below pass while testing nothing.
      const probeStuck = await editorFrame.evaluate(
        () => window.__ckWorkbenchProbe === "alive");
      if (!probeStuck) {
        return fail(
          "could not mark the editor document, so the survival assertion below " +
          "would prove nothing. The editor frame is probably still navigating.");
      }

      // The page's own identity, so a full-page reload is detectable. A reload
      // is the specific regression: it would look like a successful refresh
      // (the section appears) while having restarted the kernel.
      await page.evaluate(() => { window.__ckPageProbe = "alive"; });

      const sectionName = "Probe Section";
      await page.evaluate(() => {
        document.getElementById("add-suite-section-details").open = true;
      });
      await page.fill('#add-suite-section-details input[name="name"]', sectionName);
      await page.click('#add-suite-section-details button[type="submit"]');
      await page.waitForTimeout(2500);

      if (!page.url().includes("/workbench")) {
        return fail(
          `after creating a suite section the page left the workbench (url=${page.url()}) ` +
          `— the handler's redirect to the chromed /edit page was followed. This is ` +
          `exactly what inplace-forms.js exists to prevent.`);
      }

      const sectionLanded = await page.evaluate(
        (name) => Array.from(document.querySelectorAll(".section-header strong"))
          .some((el) => el.textContent.trim() === name),
        sectionName);
      if (!sectionLanded) {
        return fail(
          `the edit half re-rendered but "${sectionName}" is not in it — the POST did ` +
          `not land, so staying on the workbench URL proved nothing.`);
      }

      // The document was never replaced: the refresh was a DOM swap of the edit
      // half, not a reload. Without this, "the section appeared" is equally
      // consistent with a full reload that cost the kernel.
      const pageSurvived = await page
        .evaluate(() => window.__ckPageProbe === "alive")
        .catch(() => false);
      if (!pageSurvived) {
        return fail(
          "the workbench document was replaced by the write — refreshEditSurface " +
          "reloaded the page instead of swapping the edit half. That restarts the " +
          "Pyodide kernel and discards the author's unsaved cells.");
      }

      const notebookSurvived = await editorFrame
        .evaluate(() => window.__ckWorkbenchProbe === "alive")
        .catch(() => false);
      if (!notebookSurvived) {
        return fail(
          "a write replaced the editor document — the author's kernel restarted and " +
          "their unsaved cells are gone.");
      }
      console.log("suite-section write: page and kernel both intact, section landed");
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
