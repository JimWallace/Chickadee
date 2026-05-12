# Personalization — Phase 1 (per-student assignment seed)

Phase 1 of [issue #461](https://github.com/JimWallace/Chickadee/issues/461)
ships the minimum seam needed for an instructor to grade per-student
expected outputs: a stable random seed per `(student, assignment)`, surfaced
to test-script subprocesses as `CHICKADEE_ASSIGNMENT_SEED`.

No editor UI, no generator subprocess, no notebook substitution, no
manifest changes. Personalization at this stage is entirely driven inside
the instructor's test scripts.

## What Chickadee gives you

When the worker runs each test script in the test setup, it sets:

```
CHICKADEE_ASSIGNMENT_SEED=<64 lowercase hex characters>
```

- **Per (student, assignment).** Two students taking the same assignment
  see different values. The same student retesting sees the same value.
- **Stable forever.** The seed is generated lazily the first time a
  submission for that pair reaches the worker, then persisted. Manifest
  revisions, retests, and the assignment-revise fan-out (v0.4.93) do not
  rotate the seed.
- **Server-side only.** Students never see the seed in their notebook or
  the UI. It exists only in the database and in the grading subprocess.
- **Validation submissions get a seed too.** The instructor is a user; their
  validation submission carries their own seed. Useful for end-to-end checks.

If the submission has no associated user (rare — legacy pre-Phase-6
submissions), the seed is omitted and `CHICKADEE_ASSIGNMENT_SEED` is not
set. Test scripts that depend on personalization should fail closed when
the var is missing.

## Writing a Phase 1 test script

The seed is a hex string. Parse it however the assignment needs:

```python
#!/usr/bin/env python3
"""publictest_decrypt.py — Phase 1 personalized grader."""

import os
import sys

seed_hex = os.environ.get("CHICKADEE_ASSIGNMENT_SEED")
if not seed_hex:
    print("CHICKADEE_ASSIGNMENT_SEED missing — cannot grade.", file=sys.stderr)
    sys.exit(2)  # error tier

seed = int(seed_hex, 16)

# Derive per-student inputs and expected outputs locally inside the test
# script — Phase 1 has no helper-module convention yet.
plaintexts = open("quotes.txt").read().splitlines()
plaintext  = plaintexts[seed % len(plaintexts)]
shift      = seed % 26

def caesar_encode(text, shift):
    out = []
    for c in text:
        if c.isalpha():
            base = ord('a') if c.islower() else ord('A')
            out.append(chr((ord(c) - base + shift) % 26 + base))
        else:
            out.append(c)
    return ''.join(out)

ciphertext = caesar_encode(plaintext, shift)

# Drop ciphertext.txt next to the student submission so the student's
# solution.py can open it.
with open("ciphertext.txt", "w") as f:
    f.write(ciphertext)

# Run the student's decrypt() against their ciphertext and compare.
sys.path.insert(0, ".")
import solution

if not hasattr(solution, "brute_force_decrypt"):
    print("solution.py must define brute_force_decrypt(text).", file=sys.stderr)
    sys.exit(1)

got = solution.brute_force_decrypt(ciphertext)
if got == plaintext:
    print("decrypted correctly")
    sys.exit(0)
else:
    print(f"expected {plaintext!r}, got {got!r}")
    sys.exit(1)
```

The same pattern works for data-science assignments (sample rows from a
base CSV using `numpy.random.default_rng(seed)`), statistics labs (sample
from a distribution with seed-derived parameters), or arithmetic drills
(`x = (seed % 1000) + 1`).

## What is *not* in Phase 1

- The seed is **not** substituted into the student's notebook. Anything the
  student needs to see (e.g. a personalized ciphertext file) must be
  written by the test script itself into the working directory.
- There is no manifest field for personalization. No "personalize.py"
  generator. No submission/solution split on disk.
- There is no per-cell pattern kind for personalized expected values yet.

All of that lands in Phase 2 (see issue #461).

## Trust boundary

The grader's expected output is derived inside the test script from a
server-trusted env var. The student's workspace never sees the seed.
Copy-paste attacks fail: a student who copies a peer's notebook hands in a
decryption of *the peer's* ciphertext, but the grader (running with the
copier's seed) expects a different plaintext. The student cannot precompute
their own expected output because they don't know their seed.

This relies on the seed env var reaching only the grading subprocess and
not, e.g., a `print(os.environ)` cell in the student's notebook. The
worker subprocess for a test script is the only place the env var is set;
the student's JupyterLite kernel never sees it.

## Operational note

The `assignment_personalization_seeds` table is **load-bearing** for
grading correctness once an instructor adopts the pattern. Losing rows
means the seed for that `(student, assignment)` pair re-rolls on next
submission, and any submissions already graded under the old seed no
longer match their expected output. Treat this table as standard DB
backup material; do not truncate it.

Rotation is an explicit admin action and is not exposed in Phase 1. To
rotate a single student's seed (e.g. for a regrade), delete their row —
the next submission lazily generates a fresh one. Document and audit
those deletions.
