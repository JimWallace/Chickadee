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
  --check-build-flags
                   Prove, in seconds, that the build arguments still demote a
                   mutated copy's warnings, then exit. Nothing else runs. Worth
                   a row in the Swift-upgrade gauntlet: this is the check that
                   sees a toolchain quietly neutralising the flag.
  -h, --help       This message.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

config="Tools/mutation/config.json"
patch_file="Tools/mutation/0001-restore-parse-tree-cache.patch"
plan_only=0
check_flags_only=0

while [ $# -gt 0 ]; do
    case "$1" in
        --shard) SHARD="$2"; shift 2 ;;
        --file) EXPLICIT_FILES+=("$2"); shift 2 ;;
        --of) SHARD_COUNT="$2"; shift 2 ;;
        --muter-ref) MUTER_REF="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --muter-src) MUTER_SRC="$2"; shift 2 ;;
        --plan) plan_only=1; shift ;;
        --check-build-flags) check_flags_only=1; shift ;;
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
    # Constants MEASURED across run 3's three shards, not guessed. The estimate
    # used to be `mutants * 16s` with no fixed term, which understated an
    # eight-shard plan by a quarter: the per-mutant cost is lower than the pilot
    # suggested, and the setup cost it omitted is the larger of the two.
    FIXED_MIN, PER_MUTANT_S = 29, 9.8
    total = sum(load)
    est = lambda loc: FIXED_MIN + (loc // 6) * PER_MUTANT_S / 60
    print(f"{len(files)} files, {total} LOC, ~{total // 6} mutants across {count} shards")
    print(f"  (~{FIXED_MIN} min fixed per shard for the cold build + baseline, "
          f"then ~{PER_MUTANT_S}s per mutant -- both measured)")
    for i, s in enumerate(shards):
        print(f"  shard {i}: {len(s):>3} files, {load[i]:>6} LOC, ~{load[i] // 6:>4} mutants, ~{est(load[i]):>4.0f} min")
    print(f"  wall clock: ~{max(est(l) for l in load):.0f} min")
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

# ------------------------------------------------------- warning-demotion check
# PROVE, IN SECONDS, THE ONE BUILD SETTING THIS RUN CANNOT DO WITHOUT. Muter's
# RemoveSideEffects deletes the USE of a binding and leaves the binding, so a
# mutated copy is full of `let x = ...` that nothing reads. The package makes
# every warning an error, schemata put every mutant in ONE binary, and so a
# single such mutant fails the build of the whole copy: zero outcomes, after the
# shard has paid its entire build.
#
# config.json carries the demotion -- a toolset, as of Swift 6.4; the reasoning
# is there. This builds a throwaway package with the same
# `.treatAllWarnings(as: .error)` and one unused binding, using the very
# arguments that will be handed to Muter, and refuses to go on if the warning
# still lands as an error.
#
# It exists because the PREVIOUS mechanism broke silently. `-Xswiftc
# -no-warnings-as-errors` was still accepted and still printed on every command
# line after it had stopped having any effect, so the first sign of it was six
# of run 14's twelve shards reporting `error: Build failed` twelve minutes in.
# A measurement of nothing must not cost an hour to discover.
check_warning_demotion() {
    local probe
    local extra_args
    probe="${TMPDIR:-/tmp}/chickadee-mutation-flag-probe"
    rm -rf "$probe"
    mkdir -p "$probe/Sources/Probe"

    # `test`, and each `--skip <suite>`, select tests rather than affect the
    # build; everything else in testArgs is build configuration and belongs in
    # the probe. Derived rather than restated, so the probe measures whatever
    # the sweep is actually configured to use.
    mapfile -t extra_args < <(python3 - "$config" "$repo_root" <<'ARGS'
import json, sys
args = json.load(open(sys.argv[1]))["testArgs"]
out, i = [], 0
while i < len(args):
    if args[i] == "test":
        i += 1
    elif args[i] == "--skip":
        i += 2
    else:
        out.append(args[i].replace("{repoRoot}", sys.argv[2]))
        i += 1
print("\n".join(out))
ARGS
    )

    cat > "$probe/Package.swift" <<'MANIFEST'
// swift-tools-version:6.2
import PackageDescription

// Mirrors the repository's own `strictWarnings`, which is what makes an unused
// binding in a mutated copy fatal.
let package = Package(
    name: "Probe",
    targets: [
        .target(name: "Probe", swiftSettings: [.treatAllWarnings(as: .error)])
    ]
)
MANIFEST

    # Exactly the shape RemoveSideEffects leaves behind.
    cat > "$probe/Sources/Probe/Probe.swift" <<'SOURCE'
public func probe() {
    let neverRead = 42
}
SOURCE

    ( cd "$probe" && swift build "${extra_args[@]}" ) > "$probe/log.txt" 2>&1
}

echo "==> checking that a mutated copy's warnings are not errors"
if check_warning_demotion; then
    echo "    ok"
    [ "$check_flags_only" -eq 0 ] || exit 0
else
    probe_dir="${TMPDIR:-/tmp}/chickadee-mutation-flag-probe"
    echo "::error::The mutation run's warning demotion no longer works." >&2
    cat >&2 <<'EXPLAIN'
An unused binding still compiles as an ERROR under the arguments in
Tools/mutation/config.json. Muter's RemoveSideEffects produces exactly that
shape, so the mutated copy would fail to build and this shard would report zero
mutant outcomes after paying its whole build -- a measurement of nothing that
reads like a broken test suite.

Fix the demotion in Tools/mutation/config.json (and the toolset it names)
rather than reading anything from a run made without it. The probe's build log:
EXPLAIN
    sed -n '1,40p' "$probe_dir/log.txt" >&2 || true
    exit 1
fi

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

# `{repoRoot}` in a test argument becomes this checkout's path. It is there for
# the toolset that demotes warnings (see config.json): Muter runs the test
# command from inside its mutated COPY, and an absolute path into the real
# checkout is true from either directory, so the argument cannot quietly point
# at a file that is not where the run thinks it is.
python3 - "$config" "$repo_root" <<'PY' > muter.conf.yml
import json, shutil, sys
cfg = json.load(open(sys.argv[1]))
print("executable: " + (shutil.which("swift") or "/usr/bin/swift"))
print("arguments:")
for a in cfg["testArgs"]:
    print(f"  - {a.replace('{repoRoot}', sys.argv[2])}")
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
