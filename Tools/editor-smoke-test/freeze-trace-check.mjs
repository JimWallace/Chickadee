// freeze-trace-check.mjs
//
// INVESTIGATION harness (not a CI gate) for the post-boot main-thread stall:
// production freeze-watchdog beacons (`page_unresponsive`, Aug 2026) show the
// student notebook page's main thread blocking ≥8s starting ~50–60s after
// page load / kernel_idle, on Chromium, since the 0.5 xeus transition.
//
// What it does: seeds a browser-graded assignment (same flow as
// notebook-page-check.mjs), opens the REAL student notebook page in Chromium,
// waits for kernel_idle, then
//   1. applies CDP CPU throttling (FREEZE_THROTTLE, default 3x) to emulate a
//      mid-range laptop — a stall too fast to see on CI hardware inflates
//      back over the observable line;
//   2. watches for FREEZE_WATCH_MS (default 150s) with a `longtask`
//      PerformanceObserver + a watchdog-style heartbeat-gap sampler in every
//      frame, and records any real `page_unresponsive` beacon the page's own
//      freeze watchdog POSTs;
//   3. runs a CDP sampling profiler across the whole window and, for each
//      detected stall, reports the dominant stacks inside that stall's time
//      slice — the thing that was actually running.
//
// Usage:  SMOKE_CHECK=freeze-trace-check.mjs ./run-smoke.sh
// Knobs:  FREEZE_THROTTLE (default 3), FREEZE_WATCH_MS (default 150000),
//         FREEZE_PROFILE_OUT (default /tmp/freeze-trace.cpuprofile),
//         SMOKE_BROWSER_PATH (pre-installed Chromium executable).
//
// Exit 0 = ran and reported (whether or not a stall appeared); 1 = harness
// failure (seed/boot broke before the watch window even started).

import { chromium } from "playwright";
import { request as pwRequest } from "playwright";
import JSZip from "jszip";
import fs from "node:fs/promises";

const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(/\/$/, "");
const THROTTLE = parseFloat(process.env.FREEZE_THROTTLE || "3");
const WATCH_MS = parseInt(process.env.FREEZE_WATCH_MS || "150000", 10);
const PROFILE_OUT = process.env.FREEZE_PROFILE_OUT || "/tmp/freeze-trace.cpuprofile";
const KERNEL_BOOT_MS = parseInt(process.env.SMOKE_KERNEL_MS || "120000", 10);
// A main-thread task this long (under throttle) counts as a stall worth a
// stack report. Prod threshold is 8000ms unthrottled; scaled-down stalls on
// fast hardware are still the same code, so keep this low.
const STALL_MS = parseInt(process.env.FREEZE_STALL_MS || "500", 10);

const STAMP = Date.now().toString(36);
const INSTRUCTOR = { username: `frz_instr_${STAMP}`, password: "instructor-pw-123" };
const STUDENT = { username: `frz_student_${STAMP}`, password: "student-pw-123" };
const COURSE = { code: `FRZ${STAMP}`.slice(0, 12), name: "Freeze Trace Course" };

function fail(reason, extra) {
  console.log(`FREEZE-TRACE FAIL — ${reason}`);
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

// A realistic health-data-lab notebook: package imports, a sizable DataFrame
// rendered as an HTML table, and matplotlib figures. The kernel computes all
// of this on its worker thread, but RENDERING the outputs happens on the
// page's main thread — the prime suspect for the production stalls.
async function buildSetupZip() {
  const zip = new JSZip();
  const code = (src) => ({ cell_type: "code", source: [src], metadata: {}, outputs: [], execution_count: null });
  const md = (src) => ({ cell_type: "markdown", source: [src], metadata: {} });
  // FREEZE_BIG_NOTEBOOK=1: approximate a real end-of-term lab document — many
  // cells with chunky SAVED outputs (streams, HTML tables, a base64 image),
  // so document-size-scaled work (serialization, whole-notebook scans, full
  // reflows) costs what it costs in production, without running anything.
  if (process.env.FREEZE_BIG_NOTEBOOK === "1") {
    const cells = [md("## Practice lab — reopened with saved outputs\n")];
    const fakePng = "iVBORw0KGgoAAAANSUhEUg" + "A".repeat(60_000) + "==";
    const tableRows = Array.from({ length: 300 }, (_, r) =>
      `<tr><td>${r}</td><td>${(r * 1.37).toFixed(2)}</td><td>${(r % 7)}</td><td>c${r}</td></tr>`).join("");
    for (let i = 0; i < 45; i++) {
      const outputs = [];
      outputs.push({ output_type: "stream", name: "stdout", text: [`step ${i}\n`.repeat(40)] });
      if (i % 3 === 0) {
        outputs.push({
          output_type: "execute_result", execution_count: i + 1, metadata: {},
          data: { "text/html": [`<table>${tableRows}</table>`], "text/plain": ["<table>"] },
        });
      }
      if (i % 5 === 0) {
        outputs.push({
          output_type: "display_data", metadata: {},
          data: { "image/png": fakePng, "text/plain": ["<Figure>"] },
        });
      }
      cells.push({
        cell_type: "code",
        source: [`x${i} = ${i} * 2\nprint('step ${i}')\n`],
        metadata: {}, outputs, execution_count: i + 1,
      });
    }
    zip.file(
      "assignment.ipynb",
      JSON.stringify({
        nbformat: 4, nbformat_minor: 5,
        metadata: { kernelspec: { name: "python", display_name: "Python" } },
        cells,
      })
    );
    zip.file("test_public.py", 'print("public test ok")\n');
    return zip.generateAsync({ type: "nodebuffer" });
  }
  const cells = [
    md("## Blood pressure lab\n"),
    code("import numpy as np\nimport pandas as pd\nimport matplotlib.pyplot as plt\n"),
    code(
      "rng = np.random.default_rng(42)\n" +
      "n = 5000\n" +
      "df = pd.DataFrame({\n" +
      "    'patient_id': np.arange(n),\n" +
      "    'age': rng.integers(18, 90, n),\n" +
      "    'systolic': rng.normal(120, 15, n).round(1),\n" +
      "    'diastolic': rng.normal(80, 10, n).round(1),\n" +
      "    'bmi': rng.normal(26, 4, n).round(2),\n" +
      "    'smoker': rng.choice(['yes', 'no'], n),\n" +
      "    'clinic': rng.choice(['A', 'B', 'C', 'D'], n),\n" +
      "})\n" +
      "df.describe()\n"
    ),
    code("pd.set_option('display.max_rows', 1200)\ndf.head(1000)\n"),
    code(
      "fig, ax = plt.subplots(figsize=(8, 5))\n" +
      "ax.scatter(df['age'], df['systolic'], s=4, alpha=0.4)\n" +
      "ax.set_xlabel('age')\nax.set_ylabel('systolic')\nplt.show()\n"
    ),
    code(
      "fig, axes = plt.subplots(2, 2, figsize=(10, 7))\n" +
      "for ax, col in zip(axes.flat, ['age', 'systolic', 'diastolic', 'bmi']):\n" +
      "    ax.hist(df[col], bins=40)\n" +
      "    ax.set_title(col)\n" +
      "plt.tight_layout()\nplt.show()\n"
    ),
    code("df.groupby(['clinic', 'smoker']).describe()\n"),
  ];
  zip.file(
    "assignment.ipynb",
    JSON.stringify({
      nbformat: 4,
      nbformat_minor: 5,
      metadata: { kernelspec: { name: "python", display_name: "Python" } },
      cells,
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

async function expectOK(label, resPromise, okStatuses) {
  const res = await resPromise;
  if (!okStatuses.includes(res.status())) {
    let body = "";
    try { body = (await res.text()).slice(0, 400); } catch { /* ignore */ }
    throw new Error(`${label}: unexpected status ${res.status()} (wanted ${okStatuses.join("/")})\n${body}`);
  }
  return res;
}

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
  const storageState = await stud.storageState();
  await stud.dispose();
  return { setupID, storageState };
}

// ---- profile analysis -----------------------------------------------------

function frameLabel(cf) {
  const fn = cf.functionName || "(anonymous)";
  if (!cf.url) return fn;
  const file = cf.url.split("/").pop() || cf.url;
  return `${fn} @ ${file}:${(cf.lineNumber ?? -1) + 1}`;
}

// Aggregate self-time per call frame, overall and within [winStartUs, winEndUs]
// slices of the profiler clock. Returns { overall, perWindow[], nodeById }.
function analyzeProfile(profile, windowsUs) {
  const nodeById = new Map();
  const parentOf = new Map();
  for (const n of profile.nodes) nodeById.set(n.id, n);
  for (const n of profile.nodes) for (const c of n.children || []) parentOf.set(c, n.id);

  const overall = new Map();
  const perWindow = windowsUs.map(() => new Map());
  let t = profile.startTime;
  const samples = profile.samples || [];
  const deltas = profile.timeDeltas || [];
  for (let i = 0; i < samples.length; i++) {
    const dt = deltas[i] || 0;
    t += dt;
    const node = nodeById.get(samples[i]);
    if (!node) continue;
    const label = frameLabel(node.callFrame);
    overall.set(label, (overall.get(label) || 0) + dt);
    for (let w = 0; w < windowsUs.length; w++) {
      if (t >= windowsUs[w].startUs && t <= windowsUs[w].endUs) {
        const m = perWindow[w];
        m.set(samples[i], (m.get(samples[i]) || 0) + dt);
      }
    }
  }
  return { overall, perWindow, nodeById, parentOf };
}

function topEntries(map, n) {
  return [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, n);
}

function stackOf(nodeId, nodeById, parentOf, depth = 10) {
  const frames = [];
  let id = nodeId;
  while (id != null && frames.length < depth) {
    const node = nodeById.get(id);
    if (!node) break;
    frames.push(frameLabel(node.callFrame));
    id = parentOf.get(id);
  }
  return frames;
}

// ---- main -----------------------------------------------------------------

async function main() {
  console.log(`freeze-trace: seeding via ${baseURL} (throttle=${THROTTLE}x, watch=${WATCH_MS}ms)`);
  let seeded;
  try {
    seeded = await seed();
  } catch (e) {
    return fail(`seeding failed: ${(e && e.message) || e}`);
  }
  const notebookURL = `${baseURL}/testsetups/${seeded.setupID}/notebook`;
  console.log(`freeze-trace: opening ${notebookURL}`);

  const launchOptions = { headless: true, args: ["--no-sandbox"], chromiumSandbox: false };
  if (process.env.SMOKE_BROWSER_PATH) launchOptions.executablePath = process.env.SMOKE_BROWSER_PATH;
  const browser = await chromium.launch(launchOptions);
  const context = await browser.newContext({ storageState: seeded.storageState });

  // Every frame gets: kernel-diag capture (parent only receives them), a
  // longtask observer, and a watchdog-style heartbeat-gap sampler.
  await context.addInitScript(() => {
    try {
      window.__ckKernelDiag = window.__ckKernelDiag || [];
      window.addEventListener("message", (e) => {
        const d = e && e.data;
        if (d && d.ck === "kernel-diag") {
          window.__ckKernelDiag.push({ kind: d.kind, source: d.source, message: d.message, at: performance.now() });
        }
      });
      window.__ckLT = [];
      if (typeof PerformanceObserver !== "undefined") {
        const obs = new PerformanceObserver((list) => {
          for (const e of list.getEntries()) {
            window.__ckLT.push({
              start: e.startTime,
              dur: e.duration,
              attr: (e.attribution || [])
                .map((a) => a.containerType + ":" + (a.containerSrc || a.containerId || a.containerName || ""))
                .join(","),
            });
          }
        });
        try { obs.observe({ entryTypes: ["longtask"] }); } catch (_) { /* engine without longtask */ }
      }
      window.__ckGaps = [];
      let last = performance.now();
      setInterval(() => {
        const now = performance.now();
        const gap = now - last;
        if (gap > 1200) window.__ckGaps.push({ at: Math.round(last), gap: Math.round(gap) });
        last = now;
      }, 250);
    } catch (_) { /* observability only */ }
  });

  const page = await context.newPage();
  context.on("page", (p) => { p.close().catch(() => {}); });

  // The page's OWN freeze-watchdog beacons — a captured `page_unresponsive`
  // here is the production symptom reproduced exactly.
  const beacons = [];
  page.on("request", (req) => {
    try {
      if (req.method() !== "POST" || !/\/api\/v1\/client-diagnostics/.test(req.url())) return;
      const body = req.postData();
      if (!body) return;
      const j = JSON.parse(body);
      beacons.push({ kind: j.kind, source: j.source, message: j.message, wallAt: Date.now() });
    } catch (_) { /* ignore */ }
  });

  try {
    await page.goto(notebookURL, { waitUntil: "domcontentloaded", timeout: 30_000 });
    if (/\/login/.test(page.url())) return fail("redirected to login — student not authorized");

    // Wait for kernel_idle via the in-iframe collector's breadcrumbs.
    const idleDeadline = Date.now() + KERNEL_BOOT_MS;
    let idleAt = null;
    while (Date.now() < idleDeadline && idleAt == null) {
      const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
      const idle = diag.find((d) => d.kind === "kernel_phase" && d.source === "kernel_idle");
      if (idle) { idleAt = idle.at; break; }
      await page.waitForTimeout(500);
    }
    if (idleAt == null) return fail("kernel never reached idle — cannot start the watch window");
    console.log(`freeze-trace: kernel_idle at page t=${Math.round(idleAt)}ms; arming profiler + ${THROTTLE}x throttle`);

    const cdp = await context.newCDPSession(page);
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 500 });
    // Align the profiler clock with the page's performance.now() clock.
    const perfBeforeStart = await page.evaluate(() => performance.now());
    await cdp.send("Profiler.start");
    if (THROTTLE > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: THROTTLE });

    // Emulate what a student does right after boot: run the whole notebook.
    // The kernel executes on its worker thread; every OUTPUT (HTML tables,
    // figure images) renders on the shared main thread — the suspect.
    let runAll = { ok: false, why: "disabled" };
    if (process.env.FREEZE_RUN_ALL !== "0") {
      const jlf = page.frames().find((fr) => /\/jupyterlite\//.test(fr.url()));
      runAll = jlf
        ? await jlf.evaluate(async () => {
            const app = window.jupyterapp;
            if (!app || !app.commands) return { ok: false, why: "no jupyterapp.commands" };
            const ids = app.commands.listCommands().filter((c) => /run-all/.test(c));
            const id = ids.includes("notebook:run-all-cells") ? "notebook:run-all-cells" : ids[0];
            if (!id) return { ok: false, why: "no run-all command" };
            try {
              // Don't await completion — execution overlaps the watch window,
              // like a student's session. Fire and return.
              void app.commands.execute(id);
              return { ok: true, id };
            } catch (e) {
              return { ok: false, why: String(e).slice(0, 200) };
            }
          }).catch((e) => ({ ok: false, why: "evaluate failed: " + String(e).slice(0, 200) }))
        : { ok: false, why: "iframe not found" };
      console.log(`freeze-trace: run-all ${runAll.ok ? `fired (${runAll.id})` : `unavailable — ${runAll.why}`}`);
    }

    // Watch. Progress-log every 15s so a hang in the harness itself is visible.
    const watchStart = Date.now();
    while (Date.now() - watchStart < WATCH_MS) {
      await new Promise((r) => setTimeout(r, 15_000));
      const t = Math.round((Date.now() - watchStart) / 1000);
      const gaps = await page.evaluate(() => (window.__ckGaps || []).length).catch(() => "?");
      console.log(`freeze-trace: watching… +${t}s (main-thread gaps so far: ${gaps})`);
    }

    // Active probe (still under throttle): force the same specs refresh the
    // 61s KernelSpecManager poll runs, and measure how long it blocks the
    // iframe's main thread. If the passive stall and this probe agree, the
    // poll's factory is the cause, not a coincidence.
    let specProbe = { ok: false, why: "iframe not found" };
    const jlFrameForProbe = page.frames().find((fr) => /\/jupyterlite\//.test(fr.url()));
    if (jlFrameForProbe) {
      specProbe = await jlFrameForProbe.evaluate(async () => {
        const app = window.jupyterapp;
        const sm = app && app.serviceManager;
        if (!sm || !sm.kernelspecs || !sm.kernelspecs.refreshSpecs) {
          return { ok: false, why: "no serviceManager.kernelspecs.refreshSpecs" };
        }
        let longest = 0;
        let last = performance.now();
        const iv = setInterval(() => {
          const n = performance.now();
          if (n - last > longest) longest = n - last;
          last = n;
        }, 25);
        const t0 = performance.now();
        try {
          await sm.kernelspecs.refreshSpecs();
        } catch (e) {
          clearInterval(iv);
          return { ok: false, why: "refreshSpecs threw: " + String(e).slice(0, 200) };
        }
        const totalMs = Math.round(performance.now() - t0);
        clearInterval(iv);
        return { ok: true, totalMs, longestBlockMs: Math.round(longest) };
      }).catch((e) => ({ ok: false, why: "evaluate failed: " + String(e).slice(0, 200) }));
    }

    if (THROTTLE > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    const { profile } = await cdp.send("Profiler.stop");
    await fs.writeFile(PROFILE_OUT, JSON.stringify(profile));
    console.log(`freeze-trace: profile saved to ${PROFILE_OUT} (${profile.samples?.length || 0} samples)`);

    // Collect observations from the parent and the editor iframe.
    const parentObs = await page.evaluate(() => ({ lt: window.__ckLT || [], gaps: window.__ckGaps || [] }));
    const jlFrame = page.frames().find((fr) => /\/jupyterlite\//.test(fr.url()));
    let frameObs = { lt: [], gaps: [], perfPatch: "(iframe not found)" };
    if (jlFrame) {
      frameObs = await jlFrame.evaluate(() => ({
        lt: window.__ckLT || [],
        gaps: window.__ckGaps || [],
        perfPatch: window.__ckCellPerfPatch || "(not applied)",
      })).catch(() => frameObs);
    }

    // ---- report ----------------------------------------------------------
    const fmt = (ms) => `${(ms / 1000).toFixed(2)}s`;
    console.log("\n================ FREEZE TRACE REPORT ================");
    console.log(`kernel_idle at page t=${fmt(idleAt)}; watch window ${fmt(WATCH_MS)} @ ${THROTTLE}x throttle`);
    console.log(`cell-perf patch (jl-cell-perf-patch.js): ${frameObs.perfPatch}`);

    const reportSet = (label, obs) => {
      console.log(`\n-- ${label} --`);
      const stalls = obs.lt.filter((e) => e.dur >= STALL_MS);
      console.log(`long tasks ≥${STALL_MS}ms: ${stalls.length} (of ${obs.lt.length} ≥50ms)`);
      for (const s of stalls.slice(0, 20)) {
        console.log(`  at t=${fmt(s.start)} (idle+${fmt(s.start - idleAt)})  dur=${fmt(s.dur)}  attr=${s.attr || "-"}`);
      }
      if (obs.gaps.length) {
        console.log(`heartbeat gaps >1.2s: ${obs.gaps.map((g) => `t=${fmt(g.at)}+${fmt(g.gap)}`).join("  ")}`);
      }
      return stalls;
    };
    const parentStalls = reportSet("parent page (notebook.js side)", parentObs);
    reportSet("editor iframe (JupyterLite side)", frameObs);

    const watchdogBeacons = beacons.filter((b) => b.kind === "page_unresponsive");
    console.log(`\nfreeze-watchdog beacons captured: ${watchdogBeacons.length}`);
    for (const b of watchdogBeacons) console.log(`  page_unresponsive ${b.message}`);

    console.log("\n-- active probe: manual kernelspecs.refreshSpecs() under throttle --");
    console.log(
      specProbe.ok
        ? `  refreshSpecs total=${specProbe.totalMs}ms, longest main-thread block=${specProbe.longestBlockMs}ms`
        : `  probe unavailable: ${specProbe.why}`
    );

    // Profile slices for each parent-side stall (profiler clock is µs).
    const stallWindows = parentStalls.slice(0, 10).map((s) => ({
      startUs: profile.startTime + (s.start - perfBeforeStart) * 1000,
      endUs: profile.startTime + (s.start + s.dur - perfBeforeStart) * 1000,
      desc: `t=${fmt(s.start)} dur=${fmt(s.dur)}`,
    }));
    const { overall, perWindow, nodeById, parentOf } = analyzeProfile(profile, stallWindows);

    console.log("\n-- top self-time across the whole watch window --");
    for (const [label, us] of topEntries(overall, 20)) {
      console.log(`  ${fmt(us / 1000).padStart(9)}  ${label}`);
    }

    stallWindows.forEach((w, i) => {
      console.log(`\n-- inside stall ${i + 1} (${w.desc}) — dominant stacks --`);
      for (const [nodeId, us] of topEntries(perWindow[i], 5)) {
        const stack = stackOf(nodeId, nodeById, parentOf);
        console.log(`  ${fmt(us / 1000)} self:`);
        stack.forEach((fr, d) => console.log(`      ${" ".repeat(d)}${fr}`));
      }
    });

    console.log("\n================ END REPORT ================");
    await browser.close();
    process.exit(0);
  } catch (err) {
    return fail(`exception: ${(err && err.stack) || err}`);
  }
}

main();
