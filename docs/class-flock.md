# Class flock — design note

**Status: proposed (#2594). Nothing is built.** This note asks the maintainer
to decide three questions before any code. The recommendation for each is
marked.

---

## The idea

A class goal ([collaborative-class-assignments.md](collaborative-class-assignments.md),
"Class goals in force") shows its progress as a bar and a status line:

```
Seeded Bug Hunt                                    +5 pts
[============================------------]
60% of the way · 9 / 15 bugs found · 22 / 34 contributed
```

The flock shows the same progress as birds on a branch. Each student who has
contributed is one bird on the branch. As the class moves toward the goal, the
branch fills. The goal is the same and the grade is the same. Only the picture
is new.

The flock is a picture of a number the page already shows. It must not show
anything that the status line does not already say.

---

## What the page already shows

- The status line shows **how many** students contributed ("22 / 34
  contributed"). It does not show **who**.
- A leaderboard shows handles and birds, but only on an assignment that has a
  class activity and an instructor who published the board. A class goal can be
  on any assignment.
- A handle is a stable pseudonym, not anonymity (student-avatars.md, section 5).
  If the flock shows which handles contributed, a classmate can learn who did
  not contribute, by elimination, in a small section.

So a flock that names its birds tells classmates something new: who has not
contributed yet. That is the privacy question.

---

## Decisions for the maintainer

### 1. Whose birds are on the branch

| Option | What a classmate sees | New information |
|---|---|---|
| **A. Anonymous flock (recommended)** | One plain bird per contributor, all the same standing bird, in a fixed order. The viewer's own bird is drawn in its own colours if they contributed. | None. The count is already on the page. |
| B. Named flock | Each contributor's own bird and handle. | Who contributed, and by elimination who did not. |
| C. Named flock, opt-in per course | B, only when the instructor turns it on. | As B, in the courses that choose it. |

Recommendation: **A**. It gives the picture and the "that one is me" moment
with no new disclosure. B or C would need the same consent thinking as
leaderboard visibility, and a per-course setting (not an environment
variable).

### 2. Where the flock shows

- **The result page's class-goals block (recommended).** The flock replaces
  nothing: it sits above the existing bar and status line, which stay as the
  text equivalent.
- **Present mode (recommended, later).** A projector view of the flock filling
  up is the moment a class sees itself. It needs Present mode to show class
  goals at all, which it does not today.
- Not on the account page: a flock belongs to one assignment.

### 3. How it scales

A class of 300 cannot draw 300 birds in one block. Proposal:

- Draw at most **24 birds**. Below 24 contributors, one bird is one student.
  Above it, each bird stands for a share of the class, and the caption says so
  ("each bird is about 12 students").
- The viewer's own bird is always one of the drawn birds when they contributed.
- The birds use the existing sprite at `.avatar-sm`, so 24 birds cost 168 `use`
  elements, less than one leaderboard page.

---

## What it does not change

- No grade, goal shape or evaluator changes. `isSweepEvaluableClassGoal` is
  untouched.
- No new stored data: the contributor count is already computed for breadth.
- No new environment variable.
- Reduced motion: a bird that joins the branch may hop in; nothing moves under
  `prefers-reduced-motion: reduce`.

---

## Slice plan (after the decisions)

| Slice | Content |
|---|---|
| F1 | The anonymous flock above the class-goals bar on the result page, with the viewer's own bird; the 24-bird cap; tests |
| F2 | Present mode shows class goals, with the flock |
| F3 | Only if decision 1 is B or C: the named flock and its course setting |
