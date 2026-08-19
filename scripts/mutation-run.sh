#!/usr/bin/env bash
set -euo pipefail

# Run one shard of the weekly mutation sweep and write a triage report.
#
# WHY THIS PATCHES ITS OWN TOOL. Stock Muter cannot mutate this codebase, and
# fails SILENTLY when it tries -- a confident 0% with every mutant "survived".
# Two independent upstream bugs sit on opposite sides of one commit and produce
# that identical symptom:
#
#   * muter#307 -- 99624ec (PR #302) made discovery return `.sourceCodeParsed([:])`,
#     so ApplySchemata re-parses each file and rewrites a NEW syntax tree while the
#     schemata are keyed by SwiftSyntax nodes, which hash by IDENTITY. No key can
#     match, so no mutant is ever inserted. Open upstream, patches offered but
#     unmerged. Tools/mutation/0001-restore-parse-tree-cache.patch is the fix.
#   * The Swift Testing gap -- every Muter RELEASE predates 7f1f258, which added
#     `issue` to the failure-detecting regex because Swift Testing prints
#     "with 1 issue" where XCTest prints "with 1 failure". This repo has ZERO
#     XCTest across 428 test files, so a released Muter is blind to every failure
#     we produce.
#
# There is no Muter build, released or tagged, that works here. The fork is
# load-bearing, which is why the pin is exact and why the `Mutation-testing probe
# (macOS)` workflow exists to re-verify the tool after any bump.
#
# AND ITS OUTPUT IS AUDITED, NOT TRUSTED. Muter also reports mutants it never
# inserted, and they always read as "survived" -- the phantom-mutant mode of
# muter#308. Measured: one of four RemoveSideEffects mutants in
# SuiteExecution.swift pointed at a line an existing test already covers, and was
# never mutated at all. Tools/mutation/report.py checks every reported survivor
# against the guards actually present in the mutated copy and quarantines the
# phantoms. See that file for the measurement.

MUTER_REF="7f1f258"
SHARD=""
SHARD_COUNT=""
EXPLICIT_FILES=()
OUT_DIR="mutation-report"
MUTER_SRC=""

usage() {
    cat <<'USAGE'
Usage: scripts/mutation-run.sh [options]

  --shard N        Which shard to run, 0-based. Required unless --plan or --file.
  --of M           Total shards. Default: shardCount in Tools/mutation/config.json.
  --file PATH      Mutate exactly this file, bypassing sharding. Repeatable. Used
                   by the per-PR run, which mutates only what a PR changed.
  --muter-ref REF  Muter commit to build. Default 7f1f258, the pinned and measured
                   baseline. Any other ref MUST be re-verified with the
                   mutation-probe workflow first: both upstream failure modes are
                   silent, so a plausible report is not evidence the tool ran.
  --out DIR        Report destination. Default mutation-report/
  --muter-src DIR  Reuse an existing Muter checkout/build instead of cloning.
  --plan           Print the shard assignment and exit. Runs nothing.
  -h, --help       This message.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

config="Tools/mutation/config.json"
patch_file="Tools/mutation/0001-restore-parse-tree-cache.patch"
plan_only=0

while [ $# -gt 0 ]; do
    case "$1" in
        --shard) SHARD="$2"; shift 2 ;;
        --file) EXPLICIT_FILES+=("$2"); shift 2 ;;
        --of) SHARD_COUNT="$2"; shift 2 ;;
        --muter-ref) MUTER_REF="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --muter-src) MUTER_SRC="$2"; shift 2 ;;
        --plan) plan_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

command -v python3 >/dev/null || { echo "python3 not on PATH" >&2; exit 1; }
[ -n "$SHARD_COUNT" ] || SHARD_COUNT="$(python3 -c "
import json;print(json.load(open('$config'))['shardCount'])")"

# Balanced, deterministic shard assignment: biggest files first, each to the
# lightest shard. Deterministic given the same file set, so a rerun of shard 3
# mutates exactly what shard 3 mutated before.
assign() {
    python3 - "$config" "$SHARD_COUNT" "$1" <<'PY'
import json, os, sys
config, count, want = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cfg = json.load(open(config))
files = []
for root_dir in cfg["include"]:
    for root, _dirs, names in os.walk(root_dir):
        for n in sorted(names):
            if n.endswith(".swift"):
                p = os.path.join(root, n)
                files.append((sum(1 for _ in open(p, errors="ignore")), p))
files.sort(key=lambda t: (-t[0], t[1]))
shards = [[] for _ in range(count)]
load = [0] * count
for loc, path in files:
    i = load.index(min(load))
    shards[i].append(path)
    load[i] += loc
if want == "plan":
    total = sum(load)
    print(f"{len(files)} files, {total} LOC, ~{total // 6} mutants across {count} shards")
    for i, s in enumerate(shards):
        print(f"  shard {i}: {len(s):>3} files, {load[i]:>6} LOC, ~{load[i] // 6:>4} mutants, ~{load[i] // 6 * 16 // 60:>3} min")
else:
    for p in shards[int(want)]:
        print(p)
PY
}

if [ "$plan_only" -eq 1 ]; then
    assign plan
    exit 0
fi

command -v swift >/dev/null || { echo "swift not on PATH" >&2; exit 1; }

if [ "${#EXPLICIT_FILES[@]}" -gt 0 ]; then
    shard_files=("${EXPLICIT_FILES[@]}")
    label="${#shard_files[@]} changed file(s)"
    echo "==> mutating an explicit file list: $label"
else
    [ -n "$SHARD" ] || { echo "--shard is required (or use --plan / --file)" >&2; exit 2; }
    if [ "$SHARD" -ge "$SHARD_COUNT" ] || [ "$SHARD" -lt 0 ]; then
        echo "shard $SHARD out of range (0..$((SHARD_COUNT - 1)))" >&2
        exit 2
    fi
    mapfile -t shard_files < <(assign "$SHARD")
    [ "${#shard_files[@]}" -gt 0 ] || { echo "shard $SHARD is empty" >&2; exit 1; }
    label="shard $SHARD of $SHARD_COUNT"
    echo "==> $label: ${#shard_files[@]} files"
fi
printf '    %s\n' "${shard_files[@]}"

for f in "${shard_files[@]}"; do
    [ -f "$f" ] || { echo "::error::file does not exist: $f" >&2; exit 1; }
done

# ---------------------------------------------------------------- build muter
[ -n "$MUTER_SRC" ] || MUTER_SRC="${TMPDIR:-/tmp}/muter-src"
if [ ! -x "$MUTER_SRC/.build/release/muter" ]; then
    echo "==> building Muter @ $MUTER_REF (cold build is ~10 minutes)"
    if [ ! -d "$MUTER_SRC/.git" ]; then
        rm -rf "$MUTER_SRC"
        git clone --quiet https://github.com/muter-mutation-testing/muter.git "$MUTER_SRC"
    fi
    git -C "$MUTER_SRC" checkout --quiet "$MUTER_REF"
    git -C "$MUTER_SRC" checkout --quiet -- .
    # `git apply` so a drifted patch fails loudly rather than yielding a Muter
    # that silently inserts nothing.
    git -C "$MUTER_SRC" apply "$repo_root/$patch_file"
    echo "    applied $patch_file"
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

# ------------------------------------------------------------------- run it
# Muter copies the project wholesale with NO exclusions, and SwiftPM's build
# cache carries absolute paths that break in the copy. Removing .build is not an
# optimisation: without it the run dies with "missing required module
# 'SwiftShims'". The cost is a cold build inside the copy, every time.
rm -rf .build

python3 - "$config" <<'PY' > muter.conf.yml
import json, shutil, sys
cfg = json.load(open(sys.argv[1]))
print("executable: " + (shutil.which("swift") or "/usr/bin/swift"))
print("arguments:")
for a in cfg["testArgs"]:
    print(f"  - {a}")
print("exclude:")
print("  - .build")
print("mutationTestTimeout: 900")
PY

files_args=()
for f in "${shard_files[@]}"; do
    files_args+=(--files-to-mutate "$f")
done

mkdir -p "$OUT_DIR"
raw="$OUT_DIR/muter-raw.txt"

# The comparability fingerprint, recorded HERE because this is where the tool
# and toolchain actually are -- the job that merges the shards runs on a
# different image and could only guess. A mutation score is only meaningful
# against the configuration that produced it, so the trend marks any run whose
# fingerprint differs rather than drawing a line between two measurements that
# are not the same measurement. See Tools/mutation/trend.py.
python3 - "$config" "$patch_file" "$MUTER_REF" > "$OUT_DIR/env.json" <<'FINGERPRINT'
import hashlib, json, subprocess, sys

def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()[:12]

def first_line(*cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
    except OSError:
        return None
    return out.splitlines()[0].strip() if out.strip() else None

json.dump({
    "muterRef": sys.argv[3],
    "patchHash": digest(sys.argv[2]),
    "configHash": digest(sys.argv[1]),
    "swift": first_line("swift", "--version"),
    "commit": first_line("git", "rev-parse", "HEAD"),
}, sys.stdout, indent=2, sort_keys=True)
FINGERPRINT

# Muter's exit status must not abort the run: a low score is a RESULT. A genuine
# crash surfaces below as zero mutant outcomes, which IS a failure.
set +e
"$muter_bin" run --skip-coverage --skip-update-check -f plain "${files_args[@]}" 2>&1 | tee "$raw"
echo "==> muter exit status: ${PIPESTATUS[0]}"
set -e

rm -f muter.conf.yml
rm -rf muter_logs

# The mutated copy is a SIBLING of the project directory, and it is what carries
# the true mutant positions. Report before deleting it.
mutated_root="$(dirname "$PWD")/$(basename "$PWD")_mutated"
# `set -e` would abort on a non-zero report, so capture the status explicitly.
if python3 Tools/mutation/report.py "$raw" "$OUT_DIR" "$label" "$mutated_root"; then
    status=0
    rm -rf "$mutated_root"
else
    status=$?
    # KEEP the copy when the run produced nothing. It is the only artefact that
    # can say why -- a build failure there is invisible from the report alone.
    echo "==> keeping $mutated_root for diagnosis (run produced no outcomes)"
fi
exit "$status"
