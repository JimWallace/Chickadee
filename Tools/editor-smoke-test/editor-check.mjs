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
// It catches the three editor breakages we shipped blind:
//   • the COEP cross-origin-isolation attempt that BLOCKED the Pyodide kernel
//     worker (the page loaded a kernel only to refuse its worker script);
//   • a dead kernel / "Kernel Unknown" (a cell never executes);
//   • the "Page Unresponsive" freeze — input()/stdin hangs when the kernel has
//     neither the service worker nor SharedArrayBuffer for synchronous stdin.
//
// It is deliberately auth-free: the REPL and the vendored Pyodide/JupyterLite
// assets are public static content served through the SAME middleware chain
// as the student editor — including the cross-origin-isolation headers — so a
// header/middleware regression surfaces here without any course seeding.
//
// Usage:   node editor-check.mjs <baseURL>
// Exit 0 = editor healthy; exit 1 = editor broken (details printed).
//
// Env: SMOKE_SIMULATE_FROZEN=1 rewrites jupyter-lite.json in-flight to disable
// the service-worker manager, reproducing the #959 freeze config so the
// selftest can prove the input() probe actually catches it.

import { chromium } from "playwright";

const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(
  /\/$/,
  ""
);
const replURL = `${baseURL}/jupyterlite/repl/index.html?kernel=python&toolbar=1`;
const simulateFrozen = process.env.SMOKE_SIMULATE_FROZEN === "1";

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
  // `--no-sandbox` / chromiumSandbox:false: CI runs this in a root container,
  // where Chromium's setuid sandbox refuses to start. Chromium's *process*
  // sandbox is unrelated to the web-platform cross-origin-isolation / COEP
  // behaviour under test, so disabling it does not affect what we assert.
  const browser = await chromium.launch({
    headless: true,
    args: ["--no-sandbox"],
    chromiumSandbox: false,
  });
  const context = await browser.newContext();

  // Freeze simulation: strip the service-worker manager out of the editor
  // config on the wire, reproducing the #959 "Page Unresponsive" config (no SW;
  // COEP off ⇒ no SAB either). The trivial cell still runs; input() hangs.
  if (simulateFrozen) {
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
