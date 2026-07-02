// compare.mjs — diff captured screenshots against committed baselines (#1136).
//
//   node compare.mjs <baselineDir> <candidateDir> <diffDir>
//
// Pass criteria per page: identical dimensions and <= MAX_DIFF_RATIO of pixels
// differing under pixelmatch's anti-aliasing-aware comparison.  A missing
// candidate (page failed to capture) or a candidate with no baseline (new page
// added without committing its baseline) both fail.
//
// Exit 0 = all pages match; 1 = differences (diff PNGs written to <diffDir>);
// 2 = usage / IO error.
import fs from "node:fs";
import path from "node:path";
import { PNG } from "pngjs";
import pixelmatch from "pixelmatch";

const [baselineDir, candidateDir, diffDir] = process.argv.slice(2);
if (!baselineDir || !candidateDir || !diffDir) {
  console.error("usage: node compare.mjs <baselineDir> <candidateDir> <diffDir>");
  process.exit(2);
}

// Anti-aliasing / font-hinting slack: pixels must differ meaningfully
// (threshold), and up to 0.1% of the page may differ before we fail — enough
// for sub-pixel text rendering drift, far below any real palette/layout change.
const PIXEL_THRESHOLD = 0.15;
const MAX_DIFF_RATIO = 0.001;

const pngs = (dir) =>
  fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith(".png")).sort() : [];

const baselines = pngs(baselineDir);
const candidates = pngs(candidateDir);
if (baselines.length === 0) {
  console.error(`no baselines in ${baselineDir}`);
  process.exit(2);
}
fs.mkdirSync(diffDir, { recursive: true });

let failed = 0;
const report = [];

for (const name of new Set([...baselines, ...candidates])) {
  const bPath = path.join(baselineDir, name);
  const cPath = path.join(candidateDir, name);
  if (!fs.existsSync(bPath)) {
    failed++;
    report.push(`✘ ${name}: captured but has NO committed baseline — run with --update and commit it`);
    continue;
  }
  if (!fs.existsSync(cPath)) {
    failed++;
    report.push(`✘ ${name}: baseline exists but page was not captured`);
    continue;
  }
  const b = PNG.sync.read(fs.readFileSync(bPath));
  const c = PNG.sync.read(fs.readFileSync(cPath));
  if (b.width !== c.width || b.height !== c.height) {
    failed++;
    report.push(`✘ ${name}: size changed ${b.width}x${b.height} → ${c.width}x${c.height}`);
    fs.copyFileSync(cPath, path.join(diffDir, name.replace(/\.png$/, ".actual.png")));
    continue;
  }
  const diff = new PNG({ width: b.width, height: b.height });
  const diffPixels = pixelmatch(b.data, c.data, diff.data, b.width, b.height, {
    threshold: PIXEL_THRESHOLD,
  });
  const ratio = diffPixels / (b.width * b.height);
  if (ratio > MAX_DIFF_RATIO) {
    failed++;
    fs.writeFileSync(path.join(diffDir, name.replace(/\.png$/, ".diff.png")), PNG.sync.write(diff));
    fs.copyFileSync(cPath, path.join(diffDir, name.replace(/\.png$/, ".actual.png")));
    report.push(`✘ ${name}: ${diffPixels} px differ (${(ratio * 100).toFixed(3)}% > ${MAX_DIFF_RATIO * 100}%)`);
  } else {
    report.push(`✓ ${name}${diffPixels ? ` (${diffPixels} px within tolerance)` : ""}`);
  }
}

console.log(report.join("\n"));
if (failed > 0) {
  console.error(`\n${failed} page(s) differ — diff/actual images in ${diffDir}`);
  console.error("Intentional UI change?  Regenerate baselines (run-visual.sh --update) and commit them in the same PR.");
  process.exit(1);
}
console.log("\nvisual-regression: OK (all pages match baselines)");
