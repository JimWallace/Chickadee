// editor-check.mjs
//
// Headless-browser smoke test for the JupyterLite notebook editor.
//
// Boots a real chickadee-server in a browser, loads the JupyterLite REPL
// (the same Pyodide kernel + vendored assets the student editor embeds),
// and asserts the kernel actually comes up and runs a cell — the thing none
// of `swift test` / render tests / BrowserRunnerJSTests can check, because
// they never put a browser in front of the editor.
//
// This is the gate that would have caught the recent breakages:
//   • the COEP cross-origin-isolation attempt that BLOCKED the Pyodide kernel
//     worker (the page loaded a kernel only to refuse its worker script);
//   • a dead kernel / "Kernel Unknown" (cell never executes).
//
// It is deliberately auth-free: the REPL and the vendored Pyodide/JupyterLite
// assets are public static content served through the SAME middleware chain
// as the student editor — including the cross-origin-isolation headers — so a
// header/middleware regression surfaces here without any course seeding.
//
// Usage:   node editor-check.mjs <baseURL>
// Exit 0 = editor healthy; exit 1 = editor broken (details printed).

import { chromium } from "playwright";

const baseURL = (process.argv[2] || process.env.BASE_URL || "http://127.0.0.1:8099").replace(
  /\/$/,
  ""
);
const replURL = `${baseURL}/jupyterlite/repl/index.html?kernel=python&toolbar=1`;

// A distinctive expression whose result is unlikely to collide with anything
// else on the page (versions, counts, etc.), so "did the kernel run?" is a
// clean substring check.
const PROBE_EXPR = "7*191";
const PROBE_RESULT = "1337";

// Budgets. The vendored Pyodide is large but local (no network fetch), so a
// healthy kernel boots well inside these; a blocked/dead kernel blows past.
const PAGE_LOAD_MS = 30_000;
const KERNEL_RUN_MS = 90_000;

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

  const fail = (reason) => {
    console.log(`SMOKE FAIL — ${reason}`);
    if (blocked.length) {
      console.log("  blocked resources:");
      for (const b of blocked.slice(0, 8)) console.log(`    - ${b}`);
    }
    if (consoleErrors.length) {
      console.log("  console errors:");
      for (const c of consoleErrors.slice(0, 8)) console.log(`    - ${c}`);
    }
  };

  try {
    console.log(`Loading ${replURL}`);
    await page.goto(replURL, { waitUntil: "domcontentloaded", timeout: PAGE_LOAD_MS });

    const isolated = await page.evaluate(() => globalThis.crossOriginIsolated === true);
    console.log(`crossOriginIsolated = ${isolated}`);

    // Wait for the REPL's prompt input to mount (the editor shell is up).
    // The console's active prompt is the last `.cm-content`; target it
    // specifically so we don't type into the banner cell.
    const editor = page.locator(".jp-CodeConsole-input .cm-content").last();
    await editor.waitFor({ state: "visible", timeout: PAGE_LOAD_MS });

    // Drive a real cell: focus the prompt, type the probe, execute with
    // Shift+Enter (the Jupyter CodeConsole run binding — plain Enter only
    // inserts a newline). A healthy kernel echoes the result into an output
    // area; a blocked/dead kernel never does, so the output wait is our
    // liveness check. Execution submitted before the kernel finishes booting
    // is queued and runs once it is ready, so we don't pre-wait on readiness.
    await editor.click();
    await page.keyboard.type(PROBE_EXPR);
    await page.keyboard.press("Shift+Enter");

    const deadline = Date.now() + KERNEL_RUN_MS;
    let ran = false;
    while (Date.now() < deadline) {
      // Bail out early the moment we see a blocked-resource error — that's a
      // definitive COEP/worker failure, no point waiting out the full budget.
      if (blocked.length) {
        fail("blocked resource detected while waiting for the kernel (COEP worker-block)");
        await browser.close();
        process.exit(1);
      }
      const body = await page.evaluate(() => document.body.innerText).catch(() => "");
      if (body.includes(PROBE_RESULT)) {
        ran = true;
        break;
      }
      await page.waitForTimeout(500);
    }

    if (!ran) {
      fail(`kernel did not execute ${PROBE_EXPR} → ${PROBE_RESULT} within ${KERNEL_RUN_MS}ms`);
      await browser.close();
      process.exit(1);
    }

    if (blocked.length) {
      fail("kernel ran but blocked-resource errors were observed");
      await browser.close();
      process.exit(1);
    }

    console.log(`SMOKE PASS — kernel executed ${PROBE_EXPR} = ${PROBE_RESULT} (isolated=${isolated})`);
    await browser.close();
    process.exit(0);
  } catch (err) {
    fail(`exception: ${err}`);
    await browser.close();
    process.exit(1);
  }
}

main();
