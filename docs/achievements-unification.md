# Achievements unification

Status: **in progress** (this doc is the plan-of-record). Collapses the three
separate achievement editors (Class Goals, Badges, Built-in Awards) into one
**Achievements** table at the bottom of the assignment editor, where every
achievement — collaborative class goals, individual badges, and the
(formerly-hardcoded) built-in awards — is a first-class, editable row that any
instructor can add, rename, retune, or remove.

## Decisions (locked)

1. **Built-ins are seeded as editable defaults.** Every assignment's manifest
   starts with the eight built-ins as real `Achievement` rows; a one-time
   migration seeds existing assignments. They are ordinary rows, not a code
   registry + toggle. (Supersedes the `disabledBuiltInAwardIDs` toggle shipped
   in #874, which is retired in Phase D.)
2. **Trigger thresholds are parameterized.** The four per-submission badges
   carry editable numbers instead of hardcoded constants:
   | Badge | Trigger (parameterized) |
   |-------|--------------------------|
   | Ace (firstTryPerfect) | grade ≥ `threshold` (def 1.0) within `attemptThreshold` attempts (def 1) |
   | Rally (comeback) | grade jumped ≥ `jumpThresholdPercent` points (def 50) |
   | Tenacious (persistence) | grade ≥ `threshold` (def 1.0) after ≥ `attemptThreshold` attempts (def 5) |
   | Swift (speedRun) | grade ≥ `threshold` (def 1.0) with total time ≤ `timeThresholdMs` (def 2000) |
3. **Reward semantics unchanged.** Class goals grant `points` (the capped grade
   bonus); badges and class records stay cosmetic. No custom icons — the generic
   per-kind rendering is used (the `reward.icon` field stays in the model for
   back-compat but is no longer authored).

## Model changes (Core/Achievement.swift)

New optional fields, all `decodeIfPresent` (back-compat), stripped from the
runner manifest like the rest of `achievements`:

- `attemptThreshold: Int?` — Ace (max) / Tenacious (min); the ≤/≥ sense is
  intrinsic to the kind.
- `timeThresholdMs: Int?` — Swift.
- `jumpThresholdPercent: Int?` — Rally.

`threshold` (grade fraction 0…1) is reused as the grade gate for Ace / Tenacious
/ Swift, the same field class goals and threshold badges already use.

## Evaluation: manifest-driven, per kind

The mechanisms stay per-kind; only their **source** moves from the hardcoded
registry to the manifest's `achievements` array:

| Kind(s) | Mechanism (unchanged) | Source (was → becomes) |
|---------|------------------------|------------------------|
| classGoal | periodic sweep → `APIAchievementResult` | manifest (already) |
| thresholdBadge / testBadge | `earnedIndividualBadges` at display | manifest (already) |
| firstTryPerfect / comeback / persistence / speedRun | `forSubmission(BadgeContext)` | **`BuiltInAchievements.perSubmission` → manifest** |
| classRecord | `awardClassBadgesFor100Percent` + pathfinder award | **hardcoded ids → manifest classRecords** |

`BuiltInAchievements` stays as the **seed source** (the default rows) + the
registry fallback for any un-seeded/malformed manifest.

## Phases (each its own PR)

- **A — manifest-driven + parameterized evaluation** (backend, behavior-identical).
  Add the model fields; move the trigger constants into the registry defaults;
  make `forSubmission` and the class-record award logic read the manifest's
  achievements (registry fallback when none seeded).
- **B — one unified endpoint.** `GET/PUT /instructor/:id/achievements` round-trips
  the whole typed list with per-kind validation; retire `/badges` and
  `/built-in-awards`.
- **C — the unified editor table (UI).** One "Achievements" section after the
  Test Suite; one table, kind-appropriate columns, **Add Achievement → pick kind
  → fill params** (pattern-family-editor style). Drop the icon input. Delete the
  three old cards + their JS.
- **D — migration + cleanup.** Seed existing assignments; retire
  `disabledBuiltInAwardIDs` + the built-in-awards endpoint/JS; finalize this doc.

## Compatibility

- New fields are additive + `decodeIfPresent`; old manifests decode unchanged.
- Un-seeded assignments fall back to the registry so behavior is identical until
  migrated; the migration is defensive (skips malformed manifests → fallback).
- Generated test-script bytes are untouched, so `spec_hash` / `TestSetupCache`
  keys are stable.
