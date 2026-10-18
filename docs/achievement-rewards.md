# Achievements and rewards across the site

**Status: decided; S1 in progress.** The maintainer took the six open
decisions on 2026-10-17 (see "Decisions taken" at the end). Each took the
recommended answer. It continues
[achievements-unification.md](achievements-unification.md) (one editor for
every assignment achievement), [student-wardrobe.md](student-wardrobe.md)
(what a bird can earn) and [result-celebration.md](result-celebration.md)
(where a student finds out). It answers #2619 (can an achievement grant a
wardrobe item?), and it gives #2617 (one toast for everything earned) and
#2621 (the trophy case) the stored record they both need.

| Slice | Content | Issue | State |
|---|---|---|---|
| S1 | The award ledger: one stored row for each achievement a student earns | — | in progress |
| S2 | A wardrobe item as an achievement reward, on an assignment | — | proposed |
| S3 | Course achievements: the model, the course signals and the evaluator | — | proposed |
| S4 | The course Achievements tab in the instructor area | — | proposed |
| S5 | MCP parity for course achievements and the reward field | — | proposed |
| S6 | The site rules, re-expressed as achievements in code | — | proposed |
| S7 | Student surfaces: the trophy case and the one toast read the ledger | #2621, #2617 | proposed |
| S8 | Carry-through: course bundle, new term, account export, deletion | — | proposed |

---

## What this is for

Three things earn a student something today, and each one is built apart from
the other two:

| System | Where it is defined | Who can change it | Where it is evaluated | Where it is stored |
|---|---|---|---|---|
| Assignment achievements (`Achievement`) | the manifest, `achievements` | course staff, in the editor and through MCP | badges at display time, class goals in a sweep, records at ingest | badges nowhere, class goals in `achievement_results`, records in `class_achievements` |
| Wardrobe items (`WardrobeItem`) | code, one rule per item | nobody (E9), except the concept tag | when the account page or the result page loads | `wardrobe_unlocks` |
| Lab unlocks ([unlockable-labs.md](unlockable-labs.md)) | prerequisite edges on an assignment | course instructors | at ingest and on read | `assignment_unlocks` (planned) |

The maintainer wants one way to think about all of it:

- Some achievements belong to one **assignment**. These exist.
- Some belong to a **course**: "every test passed on three labs", "a graded
  submission on every lab in Unit 2", "the Ace badge three times".
- Some belong to the **site**: the built-in wardrobe rules, which count work
  in every course.
- An achievement at any level can give a **reward**: a badge, bonus points, a
  record title, or a **wardrobe item** for the bird.
- Instructors edit assignment achievements where they edit the assignment,
  and course achievements on a course page that looks the same.

Lab unlocks stay a separate system. A prerequisite edge controls when a
student may submit. An achievement never does. This note does not change
[unlockable-labs.md](unlockable-labs.md).

---

## Decisions

Each decision names the alternative it rejects. The ones that were marked
**(ask)** are decided; "Decisions taken" at the end records the answers.

### 1. One definition type, three levels

`Achievement` (Core) stays the one definition type. It gains a **level**:

```swift
public enum AchievementLevel: String, Codable, CaseIterable, Sendable {
    case assignment   // lives in the manifest, as today
    case course       // lives on the course row (decision 6)
    case site         // lives in code (decision 8)
}
```

The level is not stored on the struct. It is a fact of where the definition
lives: a manifest achievement is at the assignment level, a course-row
achievement is at the course level, and a registry achievement is at the site
level. The evaluator and the editor read the level from the container.

The alternative is a second type, `CourseAchievement`, with its own
conditions, its own editor rows and its own MCP tools. [unlockable-labs.md](unlockable-labs.md)
chose not to reuse the achievement vocabulary for unlock criteria because
every signal was one-submission-local. That objection is about the signals,
not the type. Decision 3 adds signals that read across assignments, so the
type can be shared. One type means one editor, one row shape, one validator
and one MCP schema, which is the lesson of achievements-unification.md.

### 2. Every award is stored, and it is sticky

A new table, `achievement_awards`, holds one row for each achievement a
student has earned:

| column | type | notes |
|---|---|---|
| `id` | UUID | PK |
| `user_id` | UUID | FK users, cascade delete |
| `level` | string | `assignment`, `course`, `site` |
| `owner_id` | string | the test setup ID, the course ID, or `site` |
| `achievement_id` | string | `Achievement.id` within its owner |
| `submission_id` | string NULL | the submission that earned it, when one did |
| `label` | string | the badge caption at the time it was earned, for the trophy case after the definition changes or goes away |
| `detail` | string NULL | the badge tooltip at the time it was earned |
| `earned_at` | datetime | |

Unique on `(user_id, level, owner_id, achievement_id)`. The write is an
upsert that tolerates a unique violation, like `wardrobe_unlocks`.

`owner_id` is required. A unique index treats two NULLs as different values
on both SQLite and Postgres, so a NULL owner for the site level would let one
site award be stored twice. The site level uses the owner `site`.

Today an individual badge is computed on every view (`earnedIndividualBadges`)
and stored nowhere. That is why J3 (#2617) plans a `localStorage` key for each
badge the browser has shown, and why W5 (#2621) asks what to store. A ledger
answers both. It is also what a course achievement reads for "earned the Ace
badge three times".

**Sticky (decided).** Once a row is written, a regrade does not remove it. This is
the rule for wardrobe items and for lab unlocks, and the reasons are the same:
a suite edit that retests the class must not take back what a student saw
on their result page. The alternative is to recompute badges as today, so a
badge can go away. The trophy case cannot be built on that. The display on a
submission page keeps showing the badges that submission earned, computed as
today, so a staff member who reads a regraded submission sees the truth of
that run. The ledger is the student's record, and the submission page is the
run's record.

### 3. Course signals read across assignments

`AchievementSignal` gains signals that count assignments, with the same
`atLeast` / `atMost` / `equals` comparators and the same `value`:

| Signal | Counts | Value unit |
|---|---|---|
| `assignmentsGraded` | assignments with at least one graded submission | a count |
| `assignmentsAtGrade` | assignments where the best grade is at least the condition's `gradeFloor` percent | a count |
| `assignmentsFullMarks` | assignments with a submission that passed every test it ran | a count |
| `assignmentsEarly` | assignments with a graded submission at least 48 hours before the due date (`WardrobeProgress.earlyLeadSeconds`) | a count |
| `assignmentsComeback` | assignments where every test passed after an attempt where some did not | a count |
| `achievementsEarned` | assignment-level awards in the ledger, filtered by the condition's `achievementRef` (an `Achievement.id`, or nil for any) | a count |
| `conceptsMastered` | distinct concepts with full marks on a tagged assignment | a count |

Each one is the arithmetic `WardrobeProgress` already does (`fullMarksAssignments`,
`earlyAssignments`, `comebackAssignments`, `fullMarksConcepts`). The new work
is to scope it, not to invent it.

A course signal has `allowedLevels: [.course, .site]`. The existing signals
have `allowedLevels: [.assignment]`. This is the same pattern as
`readsTheWholeClass` and `allowedScopes`: the editor's dropdown and the
validator derive the list from the enum, so a signal a level cannot evaluate
is refused at save time and never saves as a row that fires for nobody.

`AchievementTarget.kind` gains the sets a course condition may count over:

| Target kind | `ref` | Meaning |
|---|---|---|
| `courseSection` | the course section ID | assignments in that section |
| `concept` | an `AssignmentConcept` raw value | assignments tagged with that concept |
| `assignments` | a comma-separated list of assignment public IDs | exactly those assignments |
| nil | | every assignment in the course (or in every course, at the site level) |

Only assignments that students can see count. An assignment that is a draft,
or hidden, is not in the denominator, so "every lab in Unit 2" means the labs
the students know about.

`gradeFloor` and `achievementRef` are two new optional fields on
`AchievementCondition`, `decodeIfPresent`. Old manifests decode unchanged.

**Scope at the course level (decided).** Slice S3 ships `individual` only. A
`classWide` course goal ("80% of the class finishes every lab") is the same
sweep as today over a different count, and a `record` ("first to finish every
lab") is the same holder table. Both can come later on this model. Shipping
them in S3 would double the evaluator work before the first course
achievement has been used in a real offering.

### 4. A wardrobe item is a reward type

`RewardType` gains `wardrobe`, and `AchievementReward` gains `item: String?`,
a `WardrobeItem` raw value, `decodeIfPresent`:

```json
{ "type": "wardrobe", "label": "Spectrum ring", "item": "border.spectrum" }
```

The reward matrix by scope:

| Scope | Rewards it may carry |
|---|---|
| `individual` | `badge` (default), `wardrobe` |
| `classWide` | `points` (default), and `wardrobe` as well, for every student the bonus reaches |
| `record` | `title` only |

A record moves between holders, and a wardrobe item is sticky, so a record
that granted an item would give it to every holder there ever was. That is
not wrong, but it is odd, and nothing asks for it. Refuse it in S2, and
revisit if an instructor wants it.

**This answers #2619.** An achievement can grant a wardrobe item. The fixed
point stays fixed: an item an achievement grants has no built-in rule, so the
"how you earned it" text is always true. The answers to the five questions in
that issue:

1. **Which items.** A separate pool. `WardrobeItem.grantable` lists the items
   with no built-in rule. Spectrum is the first. The gradcap and the rubber
   duck join it when W4 (#2620) gives them a slot. A built-in-rule item is
   never grantable: the editor does not offer it, and the validator refuses
   it.
2. **Course items are account-wide (decided).** An item one course grants shows
   in every course. This is decision 5 of student-avatars.md, and a
   per-course wardrobe would be a second spec per enrollment. The cost is
   that the pool is shared: a student who already has spectrum from one
   course earns nothing new from another. The editor says so beside the
   control: "A student who already wears this item from another course earns
   nothing new here."
3. **The reward type.** As above. The MCP prose derives the item list from
   `WardrobeItem.grantable`, as the language lists are derived, with a
   coverage test.
4. **Trust.** Achievement conditions read the same result rows as the
   built-in rules (E10). A forged browser result can earn a cosmetic. That is
   the same acceptance E10 already made, and each new grantable item's issue
   says so.
5. **Concept rings.** They stay as they are: a built-in rule with one
   instructor tag. They cover "mastery of a concept". They do not cover "a
   reward for this lab" or "a reward for finishing the course", which is what
   the grant is for. The two do not wait on each other.

### 5. Visibility follows the reward

E1 says a wardrobe item is a surprise: a student sees no locked item, no rule
and no progress count. A badge and a class goal are the opposite: a visible
goal with a progress bar is the point of them. So:

- An achievement whose reward is `wardrobe` is **hidden until earned**, at
  every level, on every student surface. After it is earned, the account page
  says how, in the past tense, from the achievement's `name` and `detail`.
- An achievement whose reward is `badge`, `points` or `title` is **visible as
  a goal**, as today.

There is no visibility switch. The reward type decides. This keeps E1 without
a new field and without a new row in the editor.

### 6. Course achievements live on the course row

`courses.achievements`, a nullable JSON column holding `[Achievement]`,
`decodeIfPresent`. This mirrors the manifest's `achievements` array exactly,
so `AchievementsEditing.rows(fromManifest:)` and `apply` get a second source
and nothing else changes: the editor PUTs the whole list, the validator runs
once, and MCP replaces wholesale.

The alternative, one table row per course achievement, buys nothing: a
definition is never queried by field, and the editor always reads and writes
the list as a whole. A cascade on course deletion is a column delete either
way.

### 7. Evaluation runs on read, off the grading path

The wardrobe rule holds for every level: a cosmetic, and now a badge, must
never fail a grade. The evaluator runs where the wardrobe grant already runs,
and nowhere new:

| Trigger | Evaluates | Writes |
|---|---|---|
| the result page loads for the submitter | this assignment's individual achievements for this submission; this course's achievements; the site rules | ledger rows, then `wardrobe_unlocks` for any `wardrobe` reward |
| the account page loads | this student's course achievements in every active course; the site rules | the same |
| the class-goal sweep marks a goal at progress `1.0` | nothing new | a ledger row per student the bonus reaches, and the item if the goal grants one |
| ingest | nothing new | records keep `class_achievements`, as today |

One service, `AchievementAwardStore.grantEarned(for:on:)`, owns the three
evaluations and the two writes. `WardrobeUnlockStore.grantEarned` becomes the
item half of it. Nothing in `ResultIngestEffects` changes.

The cost of a course evaluation is the query `WardrobeProgress` already makes:
every graded submission of the student, joined to its result. Scope it by
course for a course achievement, and keep the whole-account read for the site
rules. A student with two hundred submissions is one query of two hundred
rows, on two pages that already pay for it.

**Lazy means late.** A student who earns a course achievement and never opens
the account page or a result page sees it on the next page that evaluates.
That is how the wardrobe works now, and nobody has asked for a push. If an
instructor wants the ledger complete for a report, a "Recompute" action on
the course Achievements tab runs `grantEarned` for every enrolled student.

### 8. The site rules move into code as achievements, behaviour identical

`WardrobeItem.earned(by:)` is six `if` statements over `WardrobeProgress`.
Each one is an `individual` achievement with one course signal and a
`wardrobe` reward:

| Item | As an achievement |
|---|---|
| `chirp` face | `assignmentsGraded atLeast 1` |
| `sly` face | a first-attempt full-marks signal; the one rule the table above does not express (see below) |
| two-tone ring | `assignmentsFullMarks atLeast 3` |
| `dreamy` face | `assignmentsEarly atLeast 3` |
| stitched ring | `assignmentsComeback atLeast 3` |
| each concept ring | `assignmentsFullMarks atLeast 1` with target `concept:<raw>` |

`BuiltInSiteAchievements` holds them, as `BuiltInAchievements` holds the
assignment defaults. The thresholds stay the named constants on
`WardrobeItem`. The pace test (E5) keeps running against the registry.

`sly` reads "a first attempt on which every test passed". It is a fact about
one submission, which the assignment-level `attempts atMost 1` plus `grade
atLeast 100` already express. At the site level it becomes
`achievementsEarned atLeast 1` with `achievementRef: first_try_perfect`, the
Ace badge, once Ace is in the ledger (S1). The catch is that Ace reads the
points-weighted grade and `sly` reads every-test-passed; on a suite with
unequal points these differ at the edge. Keep `sly` on its own
`WardrobeProgress.hasFirstTryFullMarks` flag: the maintainer decided that the
two stay two rules.

E9 still holds: there are no switches on the site rules. They are a registry,
not a course row. An instructor sees them, read-only, on the course tab, so
that the course does not grant what a student would earn anyway.

This slice (S6) is behaviour-identical and can wait. It is in the plan so that
the trophy case and the toast read one ledger instead of two tables.

### 9. Who edits what

| Surface | Read | Write |
|---|---|---|
| assignment Achievements table | course staff | `ta` and above, as today (`putAchievements`) |
| course Achievements tab | course staff | `ta` and above (decided) |
| the site registry | course staff, read-only | nobody |

A course achievement is content, like an assignment achievement, and it
changes no grade and no availability. That is the case for `ta`. The case for
`instructor` is that the tab sits beside Slip days and New term, which are
instructor-only, and that a course-wide bonus-points goal, when one ships,
reaches every grade of record. Recommended: `ta` for S3 and S4, and
`instructor` for a `classWide` course goal with `points` when that ships,
gated per row by its reward, the way `points` already needs the class sweep.

---

## Model changes (Core)

All additive, all `decodeIfPresent`, and all stripped from the runner manifest
with the rest of `achievements`.

- `AchievementLevel` (new enum, decision 1).
- `AchievementSignal`: seven course signals and `allowedLevels` (decision 3).
  `readsTheWholeClass` and `readsTheStandings` return `false` for each of
  them. `allowedScopes` returns `[.individual]` for each of them until
  decision 3's second half ships.
- `TargetKind`: `courseSection`, `concept`, `assignments` (decision 3).
- `AchievementCondition`: `gradeFloor: Double?`, `achievementRef: String?`.
- `RewardType.wardrobe` and `AchievementReward.item: String?` (decision 4).
- `WardrobeItem.grantable: [WardrobeItem]` and `WardrobeItem.hasBuiltInRule`,
  with a test that no item is in both sets.
- `CourseProgress` (new): `WardrobeProgress` generalised to a set of
  assignments, with the per-assignment facts the course signals count. It is
  built once per evaluation from `[WardrobeProgress.Graded]` plus the ledger's
  assignment-level rows, and the signals read it. `WardrobeProgress` becomes
  the site-level case of it.
- `Achievement.isSatisfied(by:)` gains an overload over `CourseProgress`.
  Every assignment signal is unmet there, and every course signal is unmet
  in the per-submission `AchievementSignals`, so a definition that reaches
  the wrong evaluator fires for nobody. The validator stops it earlier.

Server:

- `achievement_awards` and `APIAchievementAward` (decision 2).
- `wardrobe_unlocks` gains `source: String?` (`rule`, or
  `achievement:<level>:<owner>:<id>`) and `label: String?` (the achievement's
  name when it granted the item). The account page reads the stored label for
  a granted item, and `WardrobeItem.howEarned` for a rule item. The column is
  a label, not a foreign key, so an item outlives the course that gave it.
- `courses.achievements` (decision 6).
- `AchievementAwardStore` (decision 7).
- `BuiltInSiteAchievements` (decision 8).

---

## The instructor UI

### The assignment editor (S2)

The Achievements table gets one more control in the inline editor, **Reward**,
placed by scope:

- `individual`: a select, **Badge** or **Wardrobe item**. With Wardrobe item,
  a second select lists `WardrobeItem.grantable` by display name, and the
  instructor's own bird appears beside it wearing the item, drawn from the
  sprite as the account page's samples are. The note from decision 4.2 sits
  under it.
- `classWide`: the existing **Bonus points** field, plus an optional
  **Also grant** select with the same items.
- `record`: unchanged.

The table's summary cell names the reward: "Badge", "+2 points", "Spectrum
ring". `achievements-editor-core.js` already summarises a row from plain
values, and its tests run under node, so the summary rule goes there. The item
list reaches the page as `<option>` data attributes, so the script holds no
item list, as it holds no signal list.

### The course Achievements tab (S4)

A new `InstructorTab.achievements`, "Achievements", after Students in
`InstructorTab.shown`. One page, three sections:

1. **Course achievements.** The same table and the same two templates as the
   assignment editor, fed with the course signals' options and the course
   targets. The target control for a course signal is a select of three
   groups: the course's sections, the concepts, and "Chosen assignments",
   which opens a checklist of the course's assignments by title. The page
   PUTs `GET/PUT /instructor/achievements`, which call the same
   `AchievementsEditing.apply` with the course as the source.
2. **Earned so far.** Per row, how many enrolled students have the award, and
   a disclosure that lists them by name with the date. This is course staff
   reading their own course, on the web. It is not an MCP surface.
3. **Built in.** The site registry, read-only, with each item's rule in
   words, so the instructor knows what students earn with no setup.

A **Recompute** button runs `grantEarned` for every enrolled student
(decision 7). It is idempotent and it is the only write on the page besides
the table.

The page goes through `ui-review`, as every view does.

### The student surfaces (S7)

- **The result page toast** (J3, #2617) reads the rows this page load wrote
  to the ledger and to `wardrobe_unlocks`, in the order J3 fixes. The
  `localStorage` key per badge goes away: a row is written once, so a reward
  shows once.
- **The trophy case** (W5, #2621) is the ledger, grouped by course, on the
  account page, under "Your bird". Rows with a `wardrobe` reward are not in
  the case: the item is on the bird, and the result page's Earned toast
  already named it when it was earned. Rows with a `title` reward show the title and the
  assignment. Nothing locked shows (E1).
- **The course dashboard** shows a visible course achievement (decision 5) as
  one line under the section list: its name and a count, "2 of 3 labs". A
  hidden one shows nothing.

---

## MCP (S5)

- `get_achievements` and `update_achievements`: `AchievementRow` gains
  `rewardType` and `rewardItem`. The tool description derives the item list
  from `WardrobeItem.grantable` through a new `MCPWardrobeItemProse`, with a
  coverage test like `MCPTierCoverageTests`.
- `get_course_achievements` and `update_course_achievements`: course-scoped,
  `content:read` and `content:write`, the same row shape, the course signals
  and targets. Replace wholesale, as the assignment tool does.
- Neither tool, and no new tool, reports who earned what. The ledger is
  student data. The "Earned so far" section is web-only.
- Update `MCPToolCatalog.live`, `MCPServerInstructions.text`, the output
  schemas and the tool table in `docs/mcp-authoring-roadmap.md`, and run the
  three sync suites.

---

## Carry-through (S8)

- **Course bundle.** `BundledCourse` gains `achievements: [Achievement]?`.
  Import remaps `courseSection` targets through `sectionIDMap` and
  `assignments` targets through the assignment bundle-ID map that
  unlockable-labs.md plans. A target that does not resolve is dropped with a
  warning, not refused, so an old bundle still imports.
- **New term** (`CourseCloneService`) copies the course achievements with the
  same remap.
- **`clone_assignment`** keeps assignment achievements, as it does today,
  because they are in the manifest. A `wardrobe` reward clones with it.
- **Account export** adds `achievementAwards` to `profile.json`. Deletion
  cascades on `user_id`.
- **Course deletion** deletes the course's ledger rows with the course.
  Wardrobe unlocks stay, with their stored label (decision 2).
- **Assignment deletion** deletes that assignment's ledger rows, with its
  submissions. Nothing else of the assignment remains, so a trophy for it
  would name work that no longer exists. S1 does this, and the course
  deletion above, because both delete student work.
- **Retention.** A ledger row names an assignment by setup ID. When
  retention deletes a setup, the row's `label` is what the trophy case shows.

---

## What this does not do

- It does not make an achievement a prerequisite. "Lab 7 unlocks after you
  earn the Unit 2 badge" would be one more edge kind in
  [unlockable-labs.md](unlockable-labs.md), reading the ledger. That is a
  later note.
- It does not add a participation currency. The shelved section of
  student-wardrobe.md stands.
- It does not put a trophy on the bird, or on a leaderboard (student-avatars.md,
  decision 5).
- It does not add a visibility switch (decision 5 here).
- It does not change what the runner sees. Achievements never reach the
  manifest the runner reads.
- No new environment variable.

---

## Slices

Each slice is one PR. Each leaves `main` green and every existing assignment
and bird as it is.

| Slice | Content | Depends on | Decision it needs |
|---|---|---|---|
| S1 | `achievement_awards`, `APIAchievementAward`, `AchievementAwardStore` for assignment-level individual badges, written when the student's own result page and dashboard rows load. Submission pages keep computing badges for display. The rows go with the user, the course and the assignment, and are in the account export. Tests: a regrade keeps the row; two loads write one row; staff views write nothing. | — | 2 (sticky) |
| S2 | `RewardType.wardrobe`, `AchievementReward.item`, `WardrobeItem.grantable` with spectrum, `wardrobe_unlocks.source` and `label`, the grant on read, the account page's "how you earned it" from the label, the Reward control in the assignment editor, the MCP row fields and the derived prose. Closes #2619. | S1 | 4 (account-wide) |
| S3 | `AchievementLevel`, the course signals, the course targets, `CourseProgress`, `courses.achievements`, `AchievementsEditing` over a course source, the evaluator in `AchievementAwardStore`. No UI. Tests: each signal over a synthetic course; a signal at the wrong level is refused. | S1 | 3 (individual only) |
| S4 | The course Achievements tab, the two routes, Earned so far, Built in, Recompute. `ui-review`. | S3 | 9 (the gate) |
| S5 | `get_course_achievements`, `update_course_achievements`, the sync suites. | S3 | — |
| S6 | `BuiltInSiteAchievements`; `WardrobeUnlockStore` reads the registry; the pace test runs against it. Behaviour-identical. | S3 | 8 (`sly`) |
| S7 | J3 and W5 on the ledger; the course dashboard line. | S1, S3 | — |
| S8 | Bundle, new term, export, deletion, retention. | S3 | — |

S2 and S3 are independent after S1. S2 is the smaller and gives an
instructor something to use in the current term. S3 is the larger and is what
the maintainer asked for. Recommended order: S1, S2, S3, S4, S5, then S7, with
S6 and S8 as they fit.

---

## Decisions taken

The maintainer answered the six open questions on 2026-10-17. Each took the
recommended answer.

| Question | Decision |
|---|---|
| Sticky badges (decision 2) | Sticky. A stored award stays after a regrade. |
| Account-wide grants (decision 4.2) | Account-wide. An item one course grants shows in every course. |
| Course scope (decision 3) | S3 ships `individual` course achievements only. |
| The course tab's gate (decision 9) | `ta` and above, as the assignment table is. |
| `sly` and Ace (decision 8) | Two rules. `sly` keeps its own every-test-passed check. |
| A seeded completion achievement | Not yet. Spectrum stays the only grantable item until W4 gives the gradcap a slot. |
