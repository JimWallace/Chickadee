// editor-check.mjs
//
// Headless-browser smoke test for the JupyterLite notebook editor.
//
// Boots a real chickadee-server in a browser, loads the JupyterLite REPL
// (the same Pyodide kernel + vendored assets the student editor embeds),
// and asserts the kernel actually comes up and runs cells — the thing none
// of `swift test` / render tests / BrowserRunnerJSTests can check, because
// they never put a browser in front of the editor.
//
// It catches the editor breakages we shipped blind:
//   • the COEP cross-origin-isolation worker-block — when the editor page is
//     cross-origin isolated but its Pyodide kernel worker script is served
//     without COEP, Chrome refuses the worker (ERR_BLOCKED_BY_RESPONSE).  The
//     editor is now isolated unconditionally and the asset middlewares stamp
//     COEP on the worker chunk too; the default config asserts the
//     SharedArrayBuffer path boots (SMOKE_EXPECT_ISOLATED=1) and is the live
//     regression guard — if isolation regresses, the worker-block returns and
//     this fails;
//   • a dead kernel / "Kernel Unknown" (a cell never executes);
//   • the "Page Unresponsive" freeze — input()/stdin hangs when the kernel has
//     neither the service worker nor SharedArrayBuffer for synchronous stdin;
//   • a dropped / CSP-blocked in-iframe kernel-boot collector —
//     jl-kernel-diagnostics.js must actually run in the editor document and
//     postMessage kernel_phase=boot_start (proves it's injected AND executes
//     under the real CSP/COEP, beyond the build-time tag check).
//
// It is deliberately auth-free: the REPL and the vendored Pyodide/JupyterLite
// assets are public static content served through the SAME middleware chain
// as the student editor — including the cross-origin-isolation headers — so a
// header/middleware regression surfaces here without any course seeding.
//
// Usage:   node editor-check.mjs <baseURL>
// Exit 0 = editor healthy; exit 1 = editor broken (details printed).
//
// Env:
//   SMOKE_SIMULATE_FROZEN=1  rewrites jupyter-lite.json in-flight to disable the
//     service-worker manager. With isolation on, SAB still carries stdin, so the
//     editor must STAY healthy — proving the kernel no longer needs the SW.
//   SMOKE_SIMULATE_NO_SYNC=1  disables the SW AND strips the isolation headers
//     off the editor document (no SAB either), reproducing the #959 freeze so
//     the selftest can prove the input() probe actually catches it.
//   SMOKE_EXPECT_ISOLATED=1|0  asserts the page's crossOriginIsolated state so a
//     config meant to exercise the SharedArrayBuffer path can't silently pass
//     via the service-worker fallback (or vice versa).

import { chromium, webkit, firefox } from "playwright";

// Which browser engine to drive. Chromium is the default; WebKit is the
// CI-able proxy for Safari (the engine behind every Safari-class editor bug we
// have shipped — spurious phase-1 timeouts, and the `Atomics.waitAsync`
// `data:`-worker that COEP blocks). Firefox is available for completeness.
const BROWSERS = { chromium, webkit, firefox };
const browserName = process.env.SMOKE_BROWSER || "chromium";
const browserType = BROWSERS[browserName] || chromium;

const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(
  /\/$/,
  ""
);
const replURL = `${baseURL}/jupyterlite/repl/index.html?kernel=python&toolbar=1`;
// Disable the service worker on the wire (rewrite jupyter-lite.json). With
// cross-origin isolation on, SAB still carries synchronous stdin, so the editor
// must stay healthy — this proves the kernel no longer depends on the SW.
const simulateFrozen = process.env.SMOKE_SIMULATE_FROZEN === "1";
// The genuine freeze: ALSO strip the isolation headers from the editor document
// so there is no SharedArrayBuffer either. With neither the SW nor SAB, input()
// has no synchronous path and the page freezes — the scenario the freeze
// detector must still catch.
const simulateNoSync = process.env.SMOKE_SIMULATE_NO_SYNC === "1";
const disableServiceWorker = simulateFrozen || simulateNoSync;
// Simulate an engine WITHOUT native Atomics.waitAsync (older Safari / iPadOS):
// delete it before any page script runs, so the pyodide-kernel falls into its
// `data:`-worker polyfill — which COEP require-corp blocks on the cross-origin-
// isolated editor. This is the engine condition CI's modern Chromium/WebKit
// can't otherwise reach (both ship native waitAsync), and the exact trigger for
// the kernel hang the compat fallback exists to catch.
const simulateNoWaitAsync = process.env.SMOKE_SIMULATE_NO_WAITASYNC === "1";
// Optional assertion on the page's cross-origin-isolation state, so a config
// that is SUPPOSED to be isolated (SharedArrayBuffer path) can't quietly pass
// via the service-worker fallback if isolation silently regresses — and vice
// versa.  "1" ⇒ require crossOriginIsolated; "0" ⇒ require NOT isolated;
// unset ⇒ don't assert (just report).
const expectIsolated = process.env.SMOKE_EXPECT_ISOLATED;

const SERVICE_WORKER_MANAGER = "@jupyterlite/application-extension:service-worker-manager";

// A distinctive expression whose result is unlikely to collide with anything
// else on the page (versions, counts, etc.), so "did the kernel run?" is a
// clean substring check.
const PROBE_EXPR = "7*191";
const PROBE_RESULT = "1337";

// The stdin probe echoes a token back through input() — present only if the
// kernel resolved synchronous stdin without freezing the page.
const STDIN_TOKEN = "8675309";
const STDIN_MARK = `CKSTDIN=${STDIN_TOKEN}`;

// Budgets. The vendored Pyodide is large but local (no network fetch), so a
// healthy kernel boots well inside these; a blocked/dead/frozen kernel blows past.
const PAGE_LOAD_MS = 30_000;
const KERNEL_RUN_MS = 90_000;
const STDIN_PROMPT_MS = 20_000;
const STDIN_ECHO_MS = 25_000;

// Post-idle execute probe (SMOKE_POST_IDLE_MS=<ms>, default 0 = skip). After the
// kernel reaches idle, sit idle for this long, then execute one more cell and
// require it to complete. This closes the lifecycle test gap that hid the
// post-idle `exec_hang` regression: every other probe runs at t≈0, so a kernel
// whose SAB/Atomics handshake wedges only AFTER an idle period (the `[*]`-forever
// hang students hit) was never exercised. NOTE: a headless Playwright tab is
// never backgrounded/throttled, so this cannot reproduce the *production* deadlock
// (which correlates with tab-throttling on real Chrome/Edge); it is a regression
// guard that post-idle execution works at all over the live sync path.
const POST_IDLE_MS = parseInt(process.env.SMOKE_POST_IDLE_MS || "0", 10) || 0;
const POST_IDLE_EXPR = "13*53";
const POST_IDLE_RESULT = "689";

/** Console / network evidence of a blocked resource — the COEP worker-block. */
function looksBlocked(text) {
  if (!text) return false;
  return (
    text.includes("ERR_BLOCKED_BY_RESPONSE") ||
    text.includes("BlockedByResponse") ||
    text.includes("Cross-Origin-Embedder-Policy") ||
    text.includes("ERR_BLOCKED_BY_CSP") ||
    /blocked.*(worker|cross-origin)/i.test(text)
  );
}

async function main() {
  console.log(`Browser engine: ${browserName}`);
  // `--no-sandbox` / chromiumSandbox:false: CI runs this in a root container,
  // where Chromium's setuid sandbox refuses to start. Chromium's *process*
  // sandbox is unrelated to the web-platform cross-origin-isolation / COEP
  // behaviour under test, so disabling it does not affect what we assert.
  // Those flags are chromium-only; webkit/firefox launch with defaults.
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
  const context = await browser.newContext();

  // Disable the service worker on the wire by stripping its manager extension
  // out of the editor config. Used by both the frozen and no-sync configs.
  if (disableServiceWorker) {
    await context.route("**/jupyter-lite.json*", async (route) => {
      const response = await route.fetch();
      let json;
      try {
        json = JSON.parse(await response.text());
      } catch {
        return route.fulfill({ response });
      }
      const opts = (json["jupyter-config-data"] ||= {});
      const disabled = new Set(opts.disabledExtensions || []);
      disabled.add(SERVICE_WORKER_MANAGER);
      opts.disabledExtensions = [...disabled];
      route.fulfill({ response, body: JSON.stringify(json), contentType: "application/json" });
    });
  }

  // No-sync simulation: ALSO strip the isolation headers from the editor
  // document so the page is not cross-origin isolated => no SharedArrayBuffer.
  // With the SW disabled too, the kernel has no synchronous stdin path and
  // input() freezes (the #959 "Page Unresponsive" scenario) — what the freeze
  // detector must catch. (Subresources may still carry COEP/CORP; those headers
  // only constrain a loader that is itself isolated, so the page still loads.)
  if (simulateNoSync) {
    await context.route("**/repl/index.html*", async (route) => {
      const response = await route.fetch();
      const headers = { ...response.headers() };
      delete headers["cross-origin-embedder-policy"];
      delete headers["cross-origin-opener-policy"];
      route.fulfill({ response, headers });
    });
  }

  // Delete native Atomics.waitAsync so the kernel takes its `data:`-worker
  // polyfill path (the older-Safari / iPadOS condition). Registered on the
  // context so it runs in every document/frame — including the editor iframe —
  // before any page script reads `Atomics.waitAsync`.
  if (simulateNoWaitAsync) {
    await context.addInitScript(() => {
      try { delete Atomics.waitAsync; } catch (_) { /* ignore */ }
      try {
        Object.defineProperty(Atomics, "waitAsync", { value: undefined, configurable: true });
      } catch (_) { /* ignore */ }
    });
  }

  // Capture the in-iframe kernel-boot collector's breadcrumbs. jl-kernel-
  // diagnostics.js (injected into the editor document) postMessages
  // kernel_phase / kernel_error to window.parent — which is `self` for the
  // top-level REPL here — so a window 'message' listener installed before any
  // page script (addInitScript) sees them. Lets us assert end-to-end that the
  // collector is injected and that its ServiceManager status detection actually
  // fires against the real JupyterLite kernel.
  await context.addInitScript(() => {
    try {
      window.__ckKernelDiag = [];
      window.addEventListener("message", (e) => {
        const d = e && e.data;
        if (d && d.ck === "kernel-diag") {
          window.__ckKernelDiag.push({ kind: d.kind, source: d.source, message: d.message });
        }
      });
    } catch (_) { /* ignore */ }
  });

  const page = await context.newPage();

  const blocked = [];
  const consoleErrors = [];

  page.on("console", (msg) => {
    const text = msg.text();
    if (msg.type() === "error") consoleErrors.push(text);
    if (looksBlocked(text)) blocked.push(`console: ${text}`);
  });
  page.on("pageerror", (err) => {
    consoleErrors.push(String(err));
    if (looksBlocked(String(err))) blocked.push(`pageerror: ${err}`);
  });
  page.on("requestfailed", (req) => {
    const why = req.failure()?.errorText || "";
    if (looksBlocked(why) || why.includes("net::ERR_BLOCKED")) {
      blocked.push(`requestfailed: ${req.url()} — ${why}`);
    }
  });

  const fail = async (reason) => {
    console.log(`SMOKE FAIL — ${reason}`);
    if (blocked.length) {
      console.log("  blocked resources:");
      for (const b of blocked.slice(0, 8)) console.log(`    - ${b}`);
    }
    if (consoleErrors.length) {
      console.log("  console errors:");
      for (const c of consoleErrors.slice(0, 8)) console.log(`    - ${c}`);
    }
    await browser.close();
    process.exit(1);
  };

  // Poll the rendered page for `needle`, bailing early on a blocked resource.
  const waitForText = async (needle, budgetMs) => {
    const deadline = Date.now() + budgetMs;
    while (Date.now() < deadline) {
      if (blocked.length) return "blocked";
      const body = await page.evaluate(() => document.body.innerText).catch(() => "");
      if (body.includes(needle)) return true;
      await page.waitForTimeout(500);
    }
    return false;
  };

  // Submit code into the REPL's active prompt with Shift+Enter (the Jupyter
  // CodeConsole run binding — plain Enter only inserts a newline).
  const runCell = async (code) => {
    const editor = page.locator(".jp-CodeConsole-input .cm-content").last();
    await editor.waitFor({ state: "visible", timeout: PAGE_LOAD_MS });
    await editor.click();
    await page.keyboard.type(code);
    await page.keyboard.press("Shift+Enter");
  };

  try {
    console.log(`Loading ${replURL}${simulateFrozen ? " (SIMULATE_FROZEN)" : ""}`);
    await page.goto(replURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });

    const isolated = await page.evaluate(() => globalThis.crossOriginIsolated === true);
    console.log(`crossOriginIsolated = ${isolated}`);
    if (expectIsolated === "1" && !isolated) {
      return await fail(
        "expected cross-origin isolation (crossOriginIsolated=true) but the page was NOT isolated — " +
          "the SharedArrayBuffer path is not active (isolation headers missing?)"
      );
    }
    if (expectIsolated === "0" && isolated) {
      return await fail(
        "expected NO cross-origin isolation but the page WAS isolated — " +
          "isolation headers applied unexpectedly"
      );
    }

    // (0) Worker-spawn probe (only meaningful under cross-origin isolation).
    // The app's OWN Web Workers — the browser grader and the freeze failover —
    // are spawned via `new Worker(...)` from the isolated notebook page. Under
    // COEP `require-corp`, a worker whose script lacks COEP is refused by the
    // browser (ERR_BLOCKED_BY_RESPONSE), which silently breaks browser grading.
    // This regressed once (the worker scripts are not on the fast path that
    // stamps COEP); spawn them here so it can't regress unseen. These workers are
    // message-driven and do nothing until posted to, so spawning is cheap.
    if (isolated) {
      const workerScripts = ["/grading-worker.js", "/freeze-watchdog-worker.js"];
      const workerBlocked = [];
      const onWorkerReqFail = (req) => {
        const why = req.failure()?.errorText || "";
        if (workerScripts.some((s) => req.url().includes(s)) &&
            (looksBlocked(why) || /ERR_BLOCKED/i.test(why))) {
          workerBlocked.push(`${req.url()} — ${why}`);
        }
      };
      page.on("requestfailed", onWorkerReqFail);
      // Spawn in-page to trigger each worker-script fetch; a COEP block fails the
      // request (caught above). Synchronous SecurityErrors are returned too.
      const spawnErrors = await page.evaluate(async (scripts) => {
        const errs = [];
        await Promise.all(scripts.map((s) => new Promise((resolve) => {
          let w;
          try { w = new Worker(s); }
          catch (e) { errs.push(`${s} threw ${(e && e.message) || e}`); return resolve(); }
          setTimeout(() => { try { w.terminate(); } catch (_) { /* ignore */ } resolve(); }, 3000);
        })));
        return errs;
      }, workerScripts);
      await page.waitForTimeout(200);
      page.off("requestfailed", onWorkerReqFail);
      if (workerBlocked.length || spawnErrors.length) {
        return await fail(
          "an app Web Worker was blocked under cross-origin isolation (its script needs " +
            "COEP require-corp): " + [...workerBlocked, ...spawnErrors].join("; ")
        );
      }
      console.log(`worker-spawn probe: ${workerScripts.join(", ")} spawned OK under isolation`);
    }

    // (1) Liveness: a trivial cell executes. Execution submitted before the
    // kernel finishes booting is queued and runs once it is ready, so we don't
    // pre-wait on readiness.
    await runCell(PROBE_EXPR);
    const ran = await waitForText(PROBE_RESULT, KERNEL_RUN_MS);
    if (ran === "blocked") {
      return await fail("blocked resource detected while waiting for the kernel (COEP worker-block)");
    }
    if (!ran) {
      return await fail(`kernel did not execute ${PROBE_EXPR} → ${PROBE_RESULT} within ${KERNEL_RUN_MS}ms`);
    }

    // (1b) In-iframe kernel-boot collector: jl-kernel-diagnostics.js is injected
    // into the editor document and must actually RUN under the real CSP/COEP and
    // postMessage its first breadcrumb (kernel_phase=boot_start) to the parent.
    // This is distinct coverage from verify-jupyterlite.sh (which only checks the
    // <script> tag is present in the built HTML): it proves the script isn't
    // CSP-blocked or broken and that its postMessage reaches a listener. We assert
    // boot_start, not kernel_idle, because this harness drives the REPL, which —
    // unlike the production notebooks editor — does not expose the
    // `window.jupyterapp.serviceManager` hook the collector reads (the same hook
    // notebook.js's shipped watchdog uses). The kernel_idle detection itself is
    // covered by the Node unit test (mocking that ServiceManager shape) and by the
    // production hook the watchdog already relies on.
    const sawBootStart = await (async () => {
      const deadline = Date.now() + 10_000;
      while (Date.now() < deadline) {
        const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
        if (diag.some((d) => d.kind === "kernel_phase" && d.source === "boot_start")) return true;
        await page.waitForTimeout(500);
      }
      return false;
    })();
    if (!sawBootStart) {
      const diag = await page.evaluate(() => window.__ckKernelDiag || []).catch(() => []);
      return await fail(
        "the in-iframe kernel-boot collector (jl-kernel-diagnostics.js) did not emit " +
          "kernel_phase=boot_start — the script is not injected into the editor document, is " +
          "CSP-blocked, or its postMessage bridge is broken. Observed: " + JSON.stringify(diag)
      );
    }
    console.log("kernel-boot collector: observed kernel_phase=boot_start (collector running)");

    // (2) Freeze probe: input() must resolve without hanging the page. Needs
    // the service worker (or SAB) for synchronous stdin; without either, the
    // editor goes "Page Unresponsive" (#959) and the echo never returns.
    await runCell(`print("CKSTDIN=" + input())`);
    try {
      const stdin = page.locator(".jp-Stdin-input").last();
      await stdin.waitFor({ state: "visible", timeout: STDIN_PROMPT_MS });
      await stdin.fill(STDIN_TOKEN);
      await page.keyboard.press("Enter");
    } catch {
      // Prompt never rendered (or the page is frozen) — the echo wait below
      // is the arbiter and will fail the check.
    }
    const answered = await waitForText(STDIN_MARK, STDIN_ECHO_MS);
    if (answered === "blocked") {
      return await fail("blocked resource detected during the input() probe");
    }
    if (!answered) {
      return await fail(
        "input() did not return — editor froze on stdin (no service worker / SAB)"
      );
    }

    if (blocked.length) {
      return await fail("cells ran but blocked-resource errors were observed");
    }

    // (2.5) Post-idle execute regression guard (opt-in via SMOKE_POST_IDLE_MS).
    // The kernel is idle here; sit idle, then run one more cell. A kernel whose
    // execution path wedges only after idling fails this where every t≈0 probe
    // above passed. See POST_IDLE_MS for why this can't reproduce the prod hang.
    if (POST_IDLE_MS > 0) {
      console.log(`post-idle probe: idling ${POST_IDLE_MS}ms before a fresh execute…`);
      await page.waitForTimeout(POST_IDLE_MS);
      await runCell(POST_IDLE_EXPR);
      const ranAfterIdle = await waitForText(POST_IDLE_RESULT, KERNEL_RUN_MS);
      if (ranAfterIdle === "blocked") {
        return await fail("blocked resource detected during the post-idle execute probe");
      }
      if (!ranAfterIdle) {
        return await fail(
          `post-idle execute hung — kernel did not run ${POST_IDLE_EXPR} → ${POST_IDLE_RESULT} ` +
            `within ${KERNEL_RUN_MS}ms after idling ${POST_IDLE_MS}ms (exec_hang regression)`
        );
      }
      console.log(`post-idle probe: kernel ran ${POST_IDLE_EXPR}=${POST_IDLE_RESULT} after idle`);
    }

    console.log(
      `SMOKE PASS — kernel ran ${PROBE_EXPR}=${PROBE_RESULT} and input() round-tripped (isolated=${isolated})`
    );
    await browser.close();
    process.exit(0);
  } catch (err) {
    return await fail(`exception: ${err}`);
  }
}

main();
