#!/usr/bin/env bash
#
# Size guardrail for the vendored browser wasm runner (Public/runner-wasm/).
# Gates on the gzip-compressed size — universally available, including on CI
# runners without binaryen — and additionally reports brotli (what actually
# crosses the wire) when available. The point is to catch a runaway balloon —
# the signature of Embedded-Swift generic-specialization explosion, where a
# small source change produces a large binary jump — NOT to fail on normal
# incremental growth. So the ceiling is generous and the baseline delta is
# printed for visibility (update runner-size-baseline.txt when re-vendoring).
#
# Run by scripts/build-runner-wasm.sh (when re-vendoring) and by CI.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wasm=$(ls "$repo_root"/Public/runner-wasm/RunnerWasm.*.wasm 2>/dev/null | head -1 || true)
if [ -z "$wasm" ]; then
    echo "  size check: no vendored RunnerWasm.*.wasm found — skipping"
    exit 0
fi

gzip_size=$(gzip -9 -c "$wasm" | wc -c | tr -d ' ')
baseline=$(cat "$repo_root/runner-size-baseline.txt" 2>/dev/null | tr -dc '0-9' || echo 0)
baseline=${baseline:-0}

# gzip-byte thresholds. Current artifact is ~0.5 MB gzip (Embedded Swift runtime
# + JavaScriptKit + JavaScriptEventLoop + the grading core). Budget warns on
# creep; the ceiling only trips on a ~35% balloon over today's size.
BUDGET=540672   # 528 KB gzip — warn above
CEILING=688128  # 672 KB gzip — fail above

brotli_note=""
if command -v brotli >/dev/null 2>&1; then
    brotli_note=" | brotli -q11: $(brotli -q 11 -c "$wasm" | wc -c | tr -d ' ') bytes"
fi

delta_note=""
if [ "$baseline" -gt 0 ]; then
    delta=$(( gzip_size - baseline ))
    pct=$(( delta * 100 / baseline ))
    delta_note=" | Δ baseline ${delta} bytes (${pct}%)"
fi

echo "  $(basename "$wasm"): gzip ${gzip_size} bytes${brotli_note}${delta_note}"
echo "  budget ${BUDGET} (warn) / ceiling ${CEILING} (fail)"

if [ "$gzip_size" -gt "$CEILING" ]; then
    echo "  FAIL: runner wasm exceeds the hard ceiling — likely generic-specialization"
    echo "        explosion or an accidental heavy dependency. Investigate before merging."
    exit 1
elif [ "$gzip_size" -gt "$BUDGET" ]; then
    echo "  WARN: runner wasm over budget — review the size delta before merging."
fi
echo "  OK: within budget."
