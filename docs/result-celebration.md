# Result-page celebration — design note

**Status:** J1 (the bird and the celebration) shipped in #2608, and J2 (the
Earned toast for wardrobe items, #2616) has shipped. J1b (the reduced-motion
banner, #2618) and J3 (one toast for everything earned, #2617) are planned. The
design came from a design handoff ("The 100% moment", round 17); this note
records it as it applies to this codebase. The earning rules are in
[student-wardrobe.md](student-wardrobe.md), "Earning: the design pass".

---

## What this is for

A student who reaches 100%, or who improves, sees a short celebration on
their result page. Their own bird takes part. Later slices use the same moment
to tell the student about a new item (student-wardrobe.md, E11).

Two rules come from the avatar design and do not change:

- **The bird never looks sad.** A result that is the same or lower plays
  nothing, and the bird stays as it is (`Core/AvatarReaction.swift`).
- **Nothing here changes a grade.** The celebration reads the result. It
  writes nothing to it.

---

## When it plays

The celebration plays only when all of these are true:

1. The viewer is the student who made the submission. Staff who read a
   student's submission see the student's bird, but no celebration.
2. The submission is the student's latest graded submission for the
   assignment.
3. It has not played for this submission in this browser. The key is
   `localStorage["ck-celebrated:" + submissionID]`, written when the sequence
   starts. A reload does not play it again. When storage is not available, it
   plays on each load; this is acceptable.

The **server** chooses the state (`ResultCelebration` in Core) and renders it
as data attributes on the grade band. The script reads them and decides
nothing more.

| State | Condition | What plays |
|---|---|---|
| `first` | 100% now, and no earlier graded attempt on this assignment reached 100% | cascade, count-up from 0 to 100, pop, two hops, feather burst |
| `improved` | below 100%, and higher than the previous graded attempt | cascade, count-up from the previous percent, a small pop, one hop, a "+N" chip; no particles |
| `already` | 100% now, and an earlier attempt also reached 100% | sparkle only |
| none | the same or lower, a build failure, an instructor grade override, or no tests | nothing |

The percent is the autograded percent (`GradePercent.of`), without the
class-goal bonus. A grade that an instructor overrides plays nothing, because
the page shows the instructor's grade first.

---

## J1: the bird and the sequence

### The bird in the grade band

- The bird is 56px (`AvatarSize.result`, 3.5rem), to the left of the grade,
  in the `.submission-bird` group of `SubmissionPage`.
- It is the student's stored spec, ring included. Staff who read the
  submission see the same bird, as stored, with no reaction, and it does not
  move under their pointer. The existing cheer
  (`AvatarReaction`) still borrows the `chirp` face on a clean pass.
- The hops are a `translateY` on the bird's wrapper, set through a custom
  property, so the script makes no styling decision.

### Timeline (ms from the start)

`Public/celebrate.js` holds the numbers. N is the number of test rows.

| Beat | Start | Length | Detail |
|---|---|---|---|
| Test cascade | row i at `140 + 85·i` | 240 per row | The row's mark goes from "running" to its result. The mark pops: scale 0.7 to 1, with a 0.22 overshoot |
| Count-up | last row + 140 | 650 | easeOutCubic. Shows "—" before it starts (`first`) or the previous percent (`improved`). Tabular figures, so the width does not change |
| Pop | end of count-up | 340 | Grade scale 1 to 1.16 to 1 (`improved`: 1.07). At 100% the grade turns `--open-fg` |
| Bird hops | pop | 560 | Two hops of 8px. `improved`: one hop of 5px over 320 |
| Feather burst | pop | about 5000 | `first` only. See "Particles" |
| "+N" chip | pop | 450 | `improved` only. It rises 10px, fades in and pops to 1.18 |
| Sparkle | 200 | about 1000 | `already` only. Seven stars round the grade and four round the bird |

**The cascade is replayed.** The result page does not stream rows while it
grades: it polls and then reloads (`app.js`). So on the first view the page
replays the cascade with the timing above. A suite with many rows caps the
stagger at `2400 / N` ms, so the cascade ends in less than 3 seconds.

### Particles

- One `<canvas>` overlay, fixed, with no pointer events. It is scaled by the
  device pixel ratio. The animation loop stops when no particles are left,
  and pauses while the page is hidden.
- **Feathers (80%)** use the student's own bird colours and the two health
  teals. **Seeds (20%)** are heavier. Each particle lives up to 5.2 seconds
  and fades during its last 1.2 seconds.
- **The script holds no colour.** It reads each colour from a custom property
  (`getComputedStyle`), so the palette stays in `styles.css`, as the UI rules
  require. The seed and sparkle colours are tokens there.

### Reduced motion

With `prefers-reduced-motion: reduce`, nothing moves: no cascade, count-up,
pop, hop or particle. The rows and the grade render in their final state, and
the live region still reads its sentence once.

### Accessibility

- A polite live region gets one sentence at the pop: "All 8 tests passed,
  100%." or "7 of 8 tests passed, 88%, up 13 points."
- Nothing takes focus. The overlay ignores the pointer. There is no sound.

---

## J2: the Earned toast (wardrobe)

- **Server:** when the student's own result page loads with a graded result
  (off the grading path), it grants what the student has earned, with the
  same store write as the account page (`WardrobeUnlockStore.grantNew`). The
  first item that this load grants goes to the toast (`SubmissionEarnedItem`,
  `EarnedToast`). An item shows in the toast once, because a grant happens
  once. A pending result grants nothing. Course staff cannot choose a ring,
  so a ring never shows in their toast.
- **Toast:** the notebook page's graded toast in shape (`.nb-graded`, with
  `.nb-graded-earned`), fixed at the bottom right, `role="status"`, not a
  dialog. It holds the student's bird at 72px wearing the new item, a "New
  ring" or "New face" chip, the item's name, how the student earned it
  ("Earned by a first graded submission."), and **Wear it** and **Not now**
  buttons. It never closes by itself. **Not now** and Escape close it.
  Nothing takes focus.
- **Motion:** it slides in at pop + 450 ms (`celebrate.js` sends
  `chickadee:celebrate-pop` on the document). With no celebration on this
  load, it shows at once. A new ring draws in on the toast's bird from pop +
  800 to pop + 1600 ms, through a conic mask that starts at the ring art's own
  start (`AvatarRing.drawStartDegrees`: 186° for the ouroboros, 0° for the
  others). A new face crossfades from the bird's current face over 300 ms.
  Under reduced motion the toast shows in place, with the item complete.
- **Live region:** when the toast shows, it says "New ring earned: <name>." in
  its own polite region, after the celebration's sentence.
- **Wear it** is an ordinary form to `POST /account/avatar`. `earned-toast.js`
  posts it with `Accept: application/json`; the route then answers 204 (or
  422 for a refused choice) instead of a redirect, and the script points the
  page bird's layers at the new item, with no reload. When the save fails,
  the form submits as usual and lands on the account page. The toast renders
  hidden and only the script shows it, so without the script no toast shows;
  the item is still a choice on the account page.
- If two items are new at once, the toast shows the first. The others are
  choices on the account page, until J3.

## J3: one toast for everything earned

Instructor achievements use the same toast, slot and motion. One toast per
submission holds up to three rows, then "and N more", which links to the
account page. The order: wardrobe, record, badge, points, class goal. Badges
are computed for each view, so the browser keeps a key for each one shown.
Only the 100% states play the feather burst.

---

## Not decided yet

- Whether an achievement can grant a wardrobe item (student-wardrobe.md, E7).
- The concept rings that J2 shows first (C1). Their design brief is still to
  come.
