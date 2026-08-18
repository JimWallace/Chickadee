#!/usr/bin/env bash
set -euo pipefail

# Run one slice of the mutation rotation and write a triage report.
#
# WHY THIS SCRIPT EXISTS AT ALL, AND WHY IT PATCHES ITS OWN TOOL.
#
# Stock Muter cannot mutate this codebase, and fails SILENTLY when it tries --
# it reports a confident 0% with every mutant "survived". Two independent
# upstream bugs sit on opposite sides of one commit and produce that identical
# symptom:
#
#   * muter#307 -- 99624ec (PR #302) made discovery return `.sourceCodeParsed([:])`,
#     so ApplySchemata re-parses each file and rewrites a NEW syntax tree, while
#     the schemata are keyed by SwiftSyntax nodes, which hash by IDENTITY. No key
#     can ever match, so no mutant is ever inserted. Open upstream, patches
#     offered but unmerged. Tools/mutation/0001-restore-parse-tree-cache.patch is
#     the fix, applied here.
#   * The Swift Testing gap -- every Muter release predates 7f1f258, which added
#     `issue` to the failure-detecting regex because Swift Testing prints
#     "with 1 issue" where XCTest prints "with 1 failure". Chickadee has ZERO
#     XCTest across 428 test files, so a released Muter is blind to every failure
#     we produce.
#
# There is therefore no Muter build, released or tagged, that works here. The
# fork is load-bearing, which is why the pin below is exact and why the probe
# workflow exists to re-verify it after any bump. See
# docs/mutation-testing-pilot.md and docs/handoff-mutation-testing.md.
#
# A NOTE ON READING THE OUTPUT. A surviving mutant is a QUESTION, not a defect.
# Some are unkillable by construction -- JSONLite's skipWhitespace treats \n as
# skippable, but the result footer is by definition a single LINE, so no reaching
# input contains one. Never chase a score.

MUTER_REF="${MUTER_REF_DEFAULT:-7f1f258}"
SLICE_INDEX=""
OUT_DIR="mutation-report"
MUTER_SRC=""

usage() {
    cat <<'USAGE'
Usage: scripts/mutation-run.sh [options]

  --slice N        Slice index to run. Default: ISO week number modulo the
                   number of slices in Tools/mutation/slices.json.
  --muter-ref REF  Muter commit to build. Default 7f1f258 (the pinned, measured
                   baseline). Any other ref MUST be re-verified with the
                   mutation-probe workflow first -- both upstream failure modes
                   are silent.
  --out DIR        Where to write report.md and survivors.tsv. Default
                   mutation-report/
  --muter-src DIR  Reuse an existing Muter checkout/build instead of cloning.
  --list           Print the slice rotation and exit.
  -h, --help       This message.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

slices_json="Tools/mutation/slices.json"
patch_file="Tools/mutation/0001-restore-parse-tree-cache.patch"

while [ $# -gt 0 ]; do
    case "$1" in
        --slice) SLICE_INDEX="$2"; shift 2 ;;
        --muter-ref) MUTER_REF="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --muter-src) MUTER_SRC="$2"; shift 2 ;;
        --list)
            python3 -c "
import json
d = json.load(open('$slices_json'))
for i, s in enumerate(d['slices']):
    print(f\"{i}: {s['name']} ({len(s['files'])} files)\")
"
            exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

command -v swift >/dev/null || { echo "swift not on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not on PATH" >&2; exit 1; }

slice_count="$(python3 -c "import json;print(len(json.load(open('$slices_json'))['slices']))")"
if [ -z "$SLICE_INDEX" ]; then
    SLICE_INDEX=$(( 10#$(date -u +%V) % slice_count ))
fi
if [ "$SLICE_INDEX" -ge "$slice_count" ] || [ "$SLICE_INDEX" -lt 0 ]; then
    echo "slice index $SLICE_INDEX out of range (0..$((slice_count - 1)))" >&2
    exit 2
fi

slice_name="$(python3 -c "
import json;print(json.load(open('$slices_json'))['slices'][$SLICE_INDEX]['name'])")"
mapfile -t slice_files < <(python3 -c "
import json
for f in json.load(open('$slices_json'))['slices'][$SLICE_INDEX]['files']: print(f)")

echo "==> slice $SLICE_INDEX of $slice_count: $slice_name"
printf '    %s\n' "${slice_files[@]}"

missing=0
for f in "${slice_files[@]}"; do
    [ -f "$f" ] || { echo "::error::slice file does not exist: $f"; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

# ---------------------------------------------------------------- build muter
if [ -z "$MUTER_SRC" ]; then
    MUTER_SRC="${TMPDIR:-/tmp}/muter-src"
fi
if [ ! -x "$MUTER_SRC/.build/release/muter" ]; then
    echo "==> building Muter @ $MUTER_REF (cold build is ~10 minutes)"
    if [ ! -d "$MUTER_SRC/.git" ]; then
        rm -rf "$MUTER_SRC"
        git clone --quiet https://github.com/muter-mutation-testing/muter.git "$MUTER_SRC"
    fi
    git -C "$MUTER_SRC" checkout --quiet "$MUTER_REF"
    git -C "$MUTER_SRC" checkout --quiet -- .

    # The insertion fix. `git apply` so a drifted patch fails loudly rather than
    # producing a Muter that silently inserts nothing.
    git -C "$MUTER_SRC" apply "$repo_root/$patch_file"
    echo "    applied $patch_file"

    # autoreleasepool is Darwin-only and has one call site.
    if [ "$(uname -s)" != "Darwin" ]; then
        cat > "$MUTER_SRC/Sources/muterCore/Extensions/AutoreleasepoolLinux.swift" <<'SHIM'
#if !canImport(Darwin)
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif
SHIM
    fi

    ( cd "$MUTER_SRC" && swift build -c release --product muter )
fi
muter_bin="$MUTER_SRC/.build/release/muter"
echo "==> muter: $("$muter_bin" --version 2>&1 | head -1)"

# ------------------------------------------------------------------- run it
# Muter copies the project wholesale with NO exclusions, and SwiftPM's build
# cache carries absolute paths that break in the copy. Removing .build is not an
# optimisation -- without it the run dies with "missing required module
# 'SwiftShims'". The cost is a cold build inside the copy, every time.
rm -rf .build

python3 - "$slices_json" "$SLICE_INDEX" <<'PY' > muter.conf.yml
import json, shutil, sys
slice_ = json.load(open(sys.argv[1]))["slices"][int(sys.argv[2])]
print("executable: " + (shutil.which("swift") or "/usr/bin/swift"))
print("arguments:")
for a in slice_["testArgs"]:
    print(f"  - {a}")
print("exclude:")
print("  - .build")
print("mutationTestTimeout: 900")
PY
echo "==> test command: $(python3 -c "
import json;print(' '.join(json.load(open('$slices_json'))['slices'][$SLICE_INDEX]['testArgs']))")"

files_args=()
for f in "${slice_files[@]}"; do
    files_args+=(--files-to-mutate "$f")
done

mkdir -p "$OUT_DIR"
raw="$OUT_DIR/muter-raw.txt"

# Muter's exit status must not abort the run: a low score is a RESULT. A genuine
# crash surfaces below as zero mutant outcomes, which IS treated as a failure.
set +e
"$muter_bin" run --skip-coverage --skip-update-check -f plain "${files_args[@]}" 2>&1 | tee "$raw"
muter_status="${PIPESTATUS[0]}"
set -e
echo "==> muter exit status: $muter_status"

rm -f muter.conf.yml
rm -rf muter_logs

# ------------------------------------------------------------------- report
python3 - "$raw" "$OUT_DIR" "$slice_name" "$SLICE_INDEX" <<'PY'
import os, re, sys

raw, out_dir, slice_name, slice_index = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(raw, errors="ignore").read()

row = re.compile(r"^(\S+\.swift):(\d+)\s+(\S+)\s+mutant (survived|killed)", re.M)
rows = [(m.group(1), int(m.group(2)), m.group(3), m.group(4)) for m in row.finditer(text)]
survived = [r for r in rows if r[3] == "survived"]
killed = [r for r in rows if r[3] == "killed"]

score = re.search(r"Mutation Score of Test Suite:\s*(\d+)%", text)
took = re.search(r"Muter took\s+(\S+)", text)

# Resolve bare filenames back to repo paths so the report can quote the source.
paths = {}
for base, *_ in rows:
    if base in paths:
        continue
    for root, _dirs, files in os.walk("Sources"):
        if base in files:
            paths[base] = os.path.join(root, base)
            break

def source_line(base, lineno):
    p = paths.get(base)
    if not p:
        return ""
    try:
        with open(p, errors="ignore") as fh:
            for i, line in enumerate(fh, 1):
                if i == lineno:
                    return line.strip()
    except OSError:
        pass
    return ""

with open(os.path.join(out_dir, "survivors.tsv"), "w") as fh:
    fh.write("file\tline\toperator\tsource\n")
    for base, lineno, op, _ in sorted(survived):
        fh.write(f"{paths.get(base, base)}\t{lineno}\t{op}\t{source_line(base, lineno)}\n")

lines = []
lines.append(f"**Slice {slice_index}: {slice_name}**")
lines.append("")
if not rows:
    lines.append("**Muter produced no mutant outcomes at all.** That is a tooling")
    lines.append("failure, not a measurement -- most likely the insertion patch no longer")
    lines.append("applies. Do not read a score from this run; re-verify with the")
    lines.append("`Mutation-testing probe (macOS)` workflow.")
else:
    lines.append(f"| killed | survived | score | runtime |")
    lines.append(f"|---:|---:|---:|---|")
    lines.append(
        f"| {len(killed)} | {len(survived)} | "
        f"{score.group(1) + '%' if score else 'n/a'} | {took.group(1) if took else 'n/a'} |"
    )
    lines.append("")
    if survived:
        lines.append("### Survivors")
        lines.append("")
        lines.append("A survivor is a **question**, not a defect: the suite could not tell the")
        lines.append("difference when this expression changed. Some are unkillable by")
        lines.append("construction -- close those as `wontfix` with the reason, do not chase a score.")
        lines.append("")
        current = None
        for base, lineno, op, _ in sorted(survived):
            path = paths.get(base, base)
            if path != current:
                lines.append(f"\n**`{path}`**\n")
                current = path
            src = source_line(base, lineno)
            src = f" — `{src}`" if src else ""
            lines.append(f"- L{lineno} `{op}`{src}")
    else:
        lines.append("No survivors. Every mutant in this slice was killed.")

lines.append("")
lines.append("---")
lines.append("")
lines.append("Coverage here is deliberately partial: this is one slice of the rotation in")
lines.append("`Tools/mutation/slices.json`, not the tree. Method, costs and the reading")
lines.append("guide: `docs/mutation-testing-pilot.md`.")

report = "\n".join(lines) + "\n"
open(os.path.join(out_dir, "report.md"), "w").write(report)
print(report)

# No outcomes at all means the tool broke. That must fail the job -- a silent
# zero is the exact failure this whole exercise exists to avoid.
sys.exit(1 if not rows else 0)
PY
