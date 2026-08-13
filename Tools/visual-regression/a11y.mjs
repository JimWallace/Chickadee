// a11y.mjs — axe-core accessibility scan of the key pages (#1137).
//
//   node a11y.mjs <baseURL>
//
// Scans the same seeded pages as the visual harness, in BOTH colour schemes
// (contrast violations are usually scheme-specific — the dark-mode banner
// bugs fixed in #1133 were exactly this class).  Policy:
//
//   * critical / serious violations — zero tolerance, always fail;
//   * moderate / minor violations — shrink-only ratchet against the count in
//     a11y-baseline.json.  Growth fails; shrinkage prints the
//     lower-the-baseline note (mirrors the alert() / inline-script ratchets).
//
// With no a11y-baseline.json committed the scan runs in bootstrap mode: it
// reports everything, writes a suggested baseline into visual-bootstrap/ for
// the CI artifact, and exits 0 — committing the file flips it to enforcing.
import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";
import fs from "node:fs";
import path from "node:path";
import { seed } from "./seed.mjs";
import { pageList } from "./pages.mjs";

const baseURL = process.argv[2];
if (!baseURL) {
  console.error("usage: node a11y.mjs <baseURL>");
  process.exit(2);
}
const toolDir = path.dirname(new URL(import.meta.url).pathname);
const baselinePath = path.join(toolDir, "a11y-baseline.json");
const repoRoot = path.resolve(toolDir, "..", "..");

async function main() {
  console.log(`Seeding fixture data via ${baseURL} …`);
  const { setupID, instructorState, studentState, resultsPath } = await seed(baseURL);

  // Page list is shared with the visual capture — see pages.mjs.
  const PAGES = pageList({ setupID, instructorState, studentState, resultsPath });

  const browser = await chromium.launch();
  const hard = [];   // critical + serious
  const soft = [];   // moderate + minor
  for (const scheme of ["light", "dark"]) {
    for (const p of PAGES) {
      const context = await browser.newContext({
        baseURL,
        colorScheme: scheme,
        viewport: { width: 1280, height: 900 },
        storageState: p.state || undefined,
      });
      const page = await context.newPage();
      await page.goto(p.path, { waitUntil: "networkidle", timeout: 30_000 });
      const results = await new AxeBuilder({ page }).analyze();
      for (const v of results.violations) {
        const entry = {
          page: `${p.name}--${scheme}`,
          rule: v.id,
          impact: v.impact || "unknown",
          help: v.help,
          nodes: v.nodes.slice(0, 5).map((n) => n.target.join(" ")),
          nodeCount: v.nodes.length,
        };
        if (v.impact === "critical" || v.impact === "serious") hard.push(entry);
        else soft.push(entry);
      }
      await context.close();
      console.log(`scanned ${p.name}--${scheme}`);
    }
  }
  await browser.close();

  const describe = (e) =>
    `  [${e.impact}] ${e.page}: ${e.rule} — ${e.help} (${e.nodeCount} node(s): ${e.nodes.join(", ")})`;

  if (hard.length > 0) {
    console.error(`\n${hard.length} critical/serious accessibility violation(s):`);
    console.error(hard.map(describe).join("\n"));
  }
  if (soft.length > 0) {
    console.log(`\n${soft.length} moderate/minor violation(s):`);
    console.log(soft.map(describe).join("\n"));
  }

  if (!fs.existsSync(baselinePath)) {
    // Bootstrap: surface everything, suggest a baseline, pass.
    const suggested = { moderateMinor: soft.length };
    const outDir = path.join(repoRoot, "visual-bootstrap");
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(path.join(outDir, "a11y-baseline.json"), JSON.stringify(suggested, null, 2) + "\n");
    console.log(`\na11y: NO BASELINE COMMITTED — suggested a11y-baseline.json written to visual-bootstrap/.`);
    console.log(`      critical/serious found: ${hard.length} (these must be FIXED, not baselined).`);
    process.exit(0);
  }

  const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
  let failed = false;
  if (hard.length > 0) {
    console.error("\ncritical/serious violations are zero-tolerance — fix them (see above).");
    failed = true;
  }
  if (soft.length > baseline.moderateMinor) {
    console.error(`\nmoderate/minor count grew: ${soft.length} > baseline ${baseline.moderateMinor}.`);
    console.error("Fix the new violation or, if pre-existing count shifted, justify in the PR.");
    failed = true;
  } else if (soft.length < baseline.moderateMinor) {
    console.log(`\nnote: moderate/minor count dropped to ${soft.length}; lower a11y-baseline.json.`);
  }
  if (failed) process.exit(1);
  console.log("\na11y: OK (no critical/serious; moderate/minor within baseline)");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
