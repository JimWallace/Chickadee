// authoring-draft-check.mjs
//
// A staff authoring draft on the server-backed editor drive (#2925).
//
// Before #2925 the staff editor stayed on the IndexedDB drive, because the page
// rebuilt the staff copy from the stored notebook on every load. Now the copy
// is a draft (`AuthoringDraftFiles`), and this check drives it end to end on
// the real notebook page, as a course instructor who is not an admin (an
// admin passes drive checks that staff do not; see `seedInstructorAssignment`):
//
//   1. The editor opens on the server drive, and its kernel reaches idle
//      within SMOKE_KERNEL_MS. (In 2026-11 the drive answered a non-admin
//      staff listing of `users` with 403, and on WebKit the kernel then
//      stalled at "starting".)
//   2. An edit saved with Ctrl+S survives a reload (a draft, not a view).
//   3. "Save to assignment", then another edit and Ctrl+S: no "File changed"
//      dialog, because the save did not rewrite the file under the editor.
//   4. The stored notebook changes elsewhere (a save from the other view) while
//      the draft holds an unpublished edit. On reload the editor shows the
//      stored notebook, the page names the backup, and the backup holds the
//      unpublished edit.
//
// Usage:  node authoring-draft-check.mjs <baseURL>
// Env:    SMOKE_BROWSER (chromium|webkit|firefox), SMOKE_KERNEL_MS.
// Exit 0 = the draft behaves; exit 1 = a step failed (details printed).

import { chromium, webkit, firefox } from "playwright";
import { request as pwRequest } from "playwright";
import { seedInstructorAssignment } from "./seed.mjs";

const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;
const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);

const STAMP = Date.now().toString(36);
const STARTER = "CKSTARTER";
const SAVED_EDIT = `CKDRAFT_${STAMP}`;
const AFTER_PUBLISH = `CKAFTER_${STAMP}`;
const ELSEWHERE = `CKELSEWHERE_${STAMP}`;

function fail(reason, extra) {
  console.log(`AUTHORING-DRAFT FAIL — ${reason}`);
  if (extra) console.log(extra);
  process.exit(1);
}

function notebookWith(source) {
  return {
    nbformat: 4, nbformat_minor: 5,
    metadata: { kernelspec: { name: "python", display_name: "Python" } },
    cells: [{ cell_type: "code", id: "cell-one", source: [source], metadata: {}, outputs: [], execution_count: null }],
  };
}

async function findEditorFrame(page) {
  for (let i = 0; i < 60; i++) {
    const fr = page.frames().find((f) => /\/jupyterlite\//.test(f.url()));
    if (fr) return fr;
    await page.waitForTimeout(500);
  }
  return null;
}

async function frameText(frame) {
  return await frame.evaluate(() => (document.body && document.body.innerText) || "").catch(() => "");
}

async function openEditor(page, url, mustContain) {
  // The workbench can still be navigating after a save; a goto that lands
  // in that window is aborted, so try once more.
  try {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
  } catch (err) {
    if (!/ERR_ABORTED|interrupted/i.test(String(err))) throw err;
    await page.waitForTimeout(2000);
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
  }
  const frame = await findEditorFrame(page);
  if (!frame) throw new Error("the editor iframe never attached");
  const ok = await frame.waitForFunction(
    (needle) => document.querySelectorAll("[class*='jp-']").length > 20
      && ((document.body && document.body.innerText) || "").includes(needle),
    mustContain, { timeout: KERNEL_BOOT_MS }).then(() => true).catch(() => false);
  if (!ok) throw new Error(`the editor never showed "${mustContain}": ${(await frameText(frame)).slice(0, 300)}`);
  return frame;
}

async function waitForKernelIdle(page, deadline) {
  while (Date.now() < deadline) {
    const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
    if (diag.some((d) => d.kind === "kernel_phase" && d.source === "kernel_idle")) return true;
    await page.waitForTimeout(500);
  }
  return false;
}

async function appendAndSave(page, frame, marker) {
  await frame.locator(".jp-Notebook .jp-CodeCell .cm-content").first().click({ timeout: 15_000 });
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type(`\n# ${marker}\n`);
  await page.keyboard.press("ControlOrMeta+s");
  await page.waitForTimeout(2000);
}

async function main() {
  console.log(`engine=${browserName}`);
  const seeded = await seedInstructorAssignment(baseURL, {
    notebook: notebookWith(`# ${STARTER}\nx = 1\n`),
    files: { "test_x.py": "assert x == 1\n" },
    manifest: {
      schemaVersion: 1, gradingMode: "browser", language: "python", requiredFiles: [],
      testSuites: [{ tier: "public", script: "test_x.py", points: 1 }], timeLimitSeconds: 10, makefile: null,
    },
    title: `Draft Lab ${STAMP}`,
    nonAdmin: true,
  });
  // The authoring editor is the workbench: the notebook page is merged into it,
  // with its editor frame (#jl-frame) and the workbench Save (#wb-save).
  const pageURL = `${baseURL}/instructor/${seeded.assignmentID}/workbench?file=assignment`;

  const launchOptions = browserName === "chromium"
    ? { headless: true, args: ["--no-sandbox"], chromiumSandbox: false } : { headless: true };
  const browser = await browserType.launch(launchOptions);
  const context = await browser.newContext({ storageState: seeded.storageState });
  // The editor's kernel breadcrumbs (jl-kernel-diagnostics.js) reach the page
  // by postMessage; keep them where waitForKernelIdle reads them.
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
  context.on("console", (m) => log.console.push(m.text()));
  const notebookSaves = [];
  context.on("response", (r) => {
    const u = new URL(r.url());
    if (u.pathname.endsWith("/notebook/save")) notebookSaves.push(`${r.status()} ${u.pathname}${u.search}`);
    if (u.pathname.includes("/api/contents/")) log.contents.push(`${r.request().method()} ${r.status()} ${u.pathname}`);
  });
  const page = await context.newPage();
  // Accept "leave this page?": dismissing it would cancel the next reload.
  page.on("dialog", (d) => d.accept().catch(() => {}));
  const done = async (code) => { await browser.close(); process.exit(code); };

  try {
    // ---- 1 --------------------------------------------------------------
    // One budget for the load and the kernel: idle within SMOKE_KERNEL_MS.
    const idleDeadline = Date.now() + KERNEL_BOOT_MS;
    let frame = await openEditor(page, pageURL, STARTER);
    if (!log.console.some((l) => l.includes("[chickadee] server drive active"))) {
      const dbg = await page.evaluate(() => {
        const f = document.getElementById("jl-frame");
        return { url: location.href, drive: f && f.dataset.serverDrive, readOnly: f && f.dataset.readOnly,
          editor: f && f.dataset.editorUrl, save: !!document.getElementById("nb-save-assignment"), cookie: document.cookie };
      });
      return fail("the staff editor is not on the server drive", JSON.stringify(dbg) + "\n" + log.console.filter((l) => /chickadee|drive/i.test(l)).slice(0, 5).join("\n"));
    }
    if (!(await page.locator("#wb-save").count())) return fail("no workbench Save: not the authoring page");
    if (!(await waitForKernelIdle(page, idleDeadline))) {
      const phases = await page.evaluate(() => (window.__ckKernelDiag || [])
        .filter((d) => d.kind === "kernel_phase" || d.kind === "kernel_error").map((d) => d.source)).catch(() => []);
      return fail(`the kernel did not reach idle within ${KERNEL_BOOT_MS}ms as a non-admin instructor`,
        `phases: ${phases.join(" > ") || "(none)"}\n` + log.contents.filter((l) => !/ 2\d\d /.test(l)).slice(-10).join("\n"));
    }
    console.log("step 1 ok: non-admin staff editor on the server drive, kernel idle");

    // ---- 2 --------------------------------------------------------------
    await appendAndSave(page, frame, SAVED_EDIT);
    if (!log.contents.some((l) => l.startsWith("PUT 200") && l.endsWith(".ipynb"))) {
      return fail("Ctrl+S did not save the draft to the server", log.contents.slice(-10).join("\n"));
    }
    frame = await openEditor(page, pageURL, STARTER);
    await page.waitForTimeout(1500);
    if (!(await frameText(frame)).includes(SAVED_EDIT)) {
      return fail("the saved draft edit did not survive a reload", (await frameText(frame)).slice(0, 300));
    }
    console.log("step 2 ok: a saved draft edit survives a reload");

    // ---- 3 --------------------------------------------------------------
    await page.locator("#wb-save").click();
    for (let i = 0; i < 60 && !notebookSaves.length; i++) await page.waitForTimeout(500);
    if (!notebookSaves.some((l) => l.startsWith("200 "))) {
      return fail("Save to assignment did not save the notebook", notebookSaves.join("\n"));
    }
    await page.waitForTimeout(1500);
    await appendAndSave(page, frame, AFTER_PUBLISH);
    if ((await frameText(frame)).includes("has changed on disk")) {
      return fail("the save after Save to assignment raised \"File changed\"");
    }
    console.log("step 3 ok: Save to assignment, then edit + Ctrl+S, raised no conflict");

    // ---- 4 --------------------------------------------------------------
    const pageView = /[?&]view=personalized/.test(notebookSaves[0]) ? "personalized" : "template";
    const otherView = pageView === "personalized" ? "template" : "personalized";
    const api = await pwRequest.newContext({ baseURL, storageState: seeded.storageState });
    const csrf = await page.evaluate(() => document.querySelector('meta[name="csrf-token"]')?.content || "");
    const res = await api.post(`/testsetups/${seeded.setupID}/notebook/save?file=assignment&view=${otherView}`, {
      headers: { "content-type": "application/json", "x-csrf-token": csrf },
      data: JSON.stringify(notebookWith(`# ${ELSEWHERE}\nx = 2\n`)),
    });
    if (!res.ok()) return fail(`the save elsewhere returned ${res.status()}`, (await res.text()).slice(0, 300));
    frame = await openEditor(page, pageURL, ELSEWHERE);
    const text = await frameText(frame);
    if (text.includes(AFTER_PUBLISH)) return fail("the editor kept the stale draft over the newer stored notebook");
    const notice = page.locator("#nb-draft-backup-notice a");
    if (!(await notice.count())) return fail("the page did not name the backup of the unpublished edits");
    const href = await notice.getAttribute("href");
    const backup = await api.get(href);
    if (!backup.ok() || !(await backup.text()).includes(AFTER_PUBLISH)) {
      return fail(`the backup at ${href} does not hold the unpublished edit (${backup.status()})`);
    }
    await api.dispose();
    console.log(`step 4 ok: a stored change elsewhere opened the stored notebook; unpublished edits kept in ${decodeURIComponent(href.split("/").pop())}`);

    console.log(`AUTHORING-DRAFT PASS (engine=${browserName})`);
    await done(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`);
  }
}

main();
