# Achievements: deployment-readiness audit + Labs 6–9 case study (2026-07)

Status: point-in-time audit ahead of the HLTH 230 Labs 6–9 rollout
(July 8/15/22 opens). Companion to `docs/achievements-unification.md`
(the design plan-of-record). Findings reference code as of v0.4.609.

Two questions, answered in order:

1. **Audit** — is the achievements subsystem polished enough to deploy on
   the next set of labs?
2. **Case study** — design meaningful, content-integrated achievements for
   HLTH 230 Labs 6–9 and prove they are creatable through the existing
   UI + MCP authoring surfaces (and name what is not).

---

## Part 1 — Audit findings

_(filled in from the evaluation / authoring / display audits)_

---

## Part 2 — Case study: custom achievements for HLTH 230 Labs 6–9

### The labs, as authored today

All four labs are **browser-graded** (Pyodide), in `preview` visibility,
grouped under the "Labs" course section. All four still carry the eight
**uncurated built-in defaults** (Ace, Rally, Tenacious, Swift, Pathfinder,
Trailblazer, Fastest, Minimalist).

| Lab | ID | Content | Suite shape |
|-----|----|---------|-------------|
| 6 | `VTKF2H` | Food-log nutrition analysis: `copyToDictionary`, `loadFoodLog` (CSV totals), `findDeficiencies`, `findExcesses` | 4 scripts + 3 pattern families across 3 sections; 1 release test (big food log) |
| 7 | `ZGty66` | Search & complexity: benchmark timings table, Big-O of linear/binary/`hasDuplicates` | 4 public scripts, 2 sections, 60 s time limit (imports re-run student benchmarks) |
| 8 | `7kg2Aw` | Descriptive statistics on `exercise.csv`: count/min/max/mean/median, `countByGroup` | 5 pattern families + 1 release integration test, 3 sections |
| 9 | `Ze1JGH` | Capstone: NHANES hypertension classifier — `summarize`, `select_features`, `strongest_predictor`, secret accuracy ≥ 0.70 gate | 2 public + 1 release + 1 secret script; personalized cohorts via seed |

### Design principles used

- **Tie every award to the lab's learning objective**, not to generic
  submission mechanics. The badge name should teach the concept back.
- **Mix of attainable / aspirational / collaborative**: each lab gets
  roughly one "everyone should get this" badge, one stretch badge, one
  class-wide goal with a small bonus, and one competitive record.
- **Remove awards that are wrong for browser grading.** `executionTimeMs`
  on a browser-graded lab measures the *student's laptop*, not their code —
  "Swift" and the "Fastest" record become a hardware lottery. On Lab 7
  specifically, importing the notebook re-runs the n=1,000,000 benchmark
  loops, so the 2 s "Swift" default is unearnable.
- **Drop "Pathfinder" (first to submit anything)** — it rewards racing an
  empty notebook to the server at open time.

### Lab 6 — "Daily Values" set (food-log analysis)

| Achievement | Scope | Trigger | Why |
|---|---|---|---|
| **Balanced Diet** | individual | all four `findDeficiencies`/`findExcesses` case tests pass | The lab's core concept: screening totals against recommended daily values in both directions |
| **Meal Prepped** | individual | 100% on attempt 1 | Ace, rethemed to the lab |
| **Second Helping** | individual | grade jump ≥ 50 pts | Rally, rethemed |
| **Tenacious** | individual | 100% after ≥ 5 attempts | kept as-is |
| **Community Kitchen** | classWide, +1 pt | 75% of class reaches 100% | nutrition is population-level in HLTH — the class "stocks the kitchen" together |
| **First Course** | record (firstToSolve) | first student to 100% | Trailblazer, rethemed |

### Lab 7 — "Growth Rates" set (search & Big-O)

| Achievement | Scope | Trigger | Why |
|---|---|---|---|
| **Growth Mindset** | individual | all three Big-O answers correct | the analytical half of the lab |
| **Empiricist** | individual | benchmark-table test passes | the experimental half: measured timings that actually show O(log n) vs O(n) vs O(n²) |
| **Constant Time** | individual | 100% on attempt 1 | Ace retheme — "O(1): one attempt" |
| **Iterative Refinement** | individual | 100% after ≥ 5 attempts | Tenacious retheme |
| **Replication Crisis, Averted** | classWide, +1 pt | 80% of class passes the benchmark test | methods joke that lands in a health-informatics course: everyone's experiment reproduced the theory |
| **Trailblazer** | record (firstToSolve) | first to 100% | kept |

### Lab 8 — "Vital Signs" set (descriptive statistics)

| Achievement | Scope | Trigger | Why |
|---|---|---|---|
| **Full Panel** | individual | final case of each stats family passes (max/mean/median/countByGroup) | "ordered the full panel" — the lab's five descriptive measures |
| **Clinical Significance** | individual | release integration test passes | reproduces published pulse values for both diet groups on the real dataset |
| **Outlier** | individual | 100% on attempt 1 | Ace retheme — a statistical outlier |
| **Significant Improvement** | individual | grade jump ≥ 50 pts | Rally retheme (p < 0.05) |
| **Sample Size Matters** | individual | 100% after ≥ 5 attempts | Tenacious retheme — more samples, better estimate |
| **Well-Powered Study** | classWide, +1 pt | 85% of class reaches 100% | statistical power as a collaborative goal |
| **Trailblazer** | record (firstToSolve) | first to 100% | kept |

### Lab 9 — "Predict It" set (hypertension classifier capstone)

| Achievement | Scope | Trigger | Why |
|---|---|---|---|
| **Epidemiologist** | individual | `strongest_predictor` release test passes | found the strongest hypertension correlate in their personal cohort |
| **Clinical Grade** | individual | secret accuracy test passes | "your model clears the deployment bar" — deliberately surfaces pass/fail of the hidden ≥ 0.70 gate as motivation without revealing its internals (see tier-leak caveat in Part 1) |
| **Breakthrough** | individual | grade jump ≥ 50 pts | Rally retheme |
| **Hyperparameter Grind** | individual | 100% after ≥ 5 attempts | Tenacious retheme — iterating on feature sets |
| **Population Health** | classWide, +1 pt | 70% of class passes the accuracy gate | screening programs only work at population scale — the course's closing argument, as a badge |
| **First Diagnosis** | record (firstToSolve) | first to 100% | Trailblazer retheme |

### Exact MCP payloads

_(appended after feasibility run — see Part 3)_

---

## Part 3 — Creatability through the existing surfaces

_(filled in after the authoring audit + live MCP feasibility run)_
