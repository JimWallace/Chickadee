# Student wardrobe — design note

**Status:** slice W1 is being built (border and backdrop colour, chosen on the
account page). Everything after W1 is a plan. The participation currency is
**shelved**: the maintainer decided that the first idea for it ("seeds") is
not fun enough, and we will come back to it.

This note continues [student-avatars.md](student-avatars.md). Read decisions 2
and 5 there first: the spec is stored and drawn once, unlocks are account-wide,
and the wardrobe is lateral.

---

## What this is for

Students get small cosmetic choices for their chickadee. The purpose is to make
the platform a little more personal. Nothing here changes a grade, and nothing
here can.

Later, some items become **earned**: an achievement in a lab, a place in a class
activity, or the completion of a course. The order of work is deliberate. First
we make the choosing work and look right. Then we add the things there are to
earn.

---

## Three kinds of thing, kept separate

1. **Wardrobe.** Items the bird WEARS: a border, a backdrop colour, and later
   accessories. The wardrobe is lateral. An item is different, not better. A
   wardrobe item may show anywhere the bird shows.
2. **Trophy case** (planned). A shelf of earned medals and concept badges, on
   the account page ONLY. A trophy says "better", so it is never drawn on the
   bird. If it were, a leaderboard would carry a second scoreboard, which
   decision 5 forbids.
3. **Currency** (shelved). Points for engagement that a student spends on
   wardrobe items. See "Shelved" below.

---

## Decisions

### 1. A student chooses the border and the backdrop; the draw does not

The backdrop was a drawn axis. It stays one: a new student still gets a random
backdrop, so nobody has to choose anything. On the account page the student can
change it to any of the eight backdrop colours.

The border is new, and it is **chosen, never drawn**. Every bird starts with no
border. The options are the five accent colours. Because nobody is drawn a
border, the border is not in `AvatarSpec.combinationCount`, which counts the
birds a draw can produce.

### 2. The border is a CSS outline, not a sprite layer

The ring is `outline` on the avatar element with a negative `outline-offset`,
coloured by a per-student custom property, `--av-border`. This has three
advantages:

- There is no new geometry, so the sprite rules and the layer order do not
  change.
- An outline follows `border-radius` on current engines, so the ring is round.
- `outline-style` already has `dashed`, `dotted` and `double`. A later
  "stitched" or "double" ring is one CSS rule, not new art.

"No border" is not a special case. The presentation sets `--av-border` to
`--avatar-border-none`, which is transparent, so the ring paints nothing and
a bird with no border is exactly the bird it was before borders existed. The
template has no condition. (A first version used the backdrop colour for
"none". That was wrong: an opaque ring in the backdrop colour covers the outer
band of the disc, and the scarf tail and the beanie pom reach into it.)

A chosen ring is inside the disc, so it paints over the outer band. A hat or a
scarf that reaches the edge goes under the ring. This looks like the bird is in
a frame.

`.avatar` sets `forced-color-adjust: none`. The bird is decorative and its
colours are the student's; without this, forced-colors mode repaints the bird
and draws the transparent ring in the system colour.

### 3. One chokepoint validates every change

`AvatarCustomization` (Core) is the only thing that applies a student's choice
to a spec. It lists the slots a student may change and the options that are
open to them. Today every option of the two slots is open. When unlocks arrive,
this is the one place that checks them, in the same shape as
`evaluateCourseWrite`. The route never writes a spec field itself.

The request carries raw values. A value that is not a case of the slot's enum,
or a slot that the student may not change, is refused. The spec is not changed.

### 4. The gradcap becomes an earned item; the headband replaces it

The gradcap reads as "graduated", so it is kept for a later course-completion
or cumulative achievement. It leaves the first-use draw:

- `AvatarAccessory` gains `headband` (appended, never inserted).
- `AvatarAccessory.starterCases` lists the eight starter accessories, and the
  draw picks only from it. This is the same shape as
  `AvatarExpression.starterCases`.
- **Existing gradcaps become headbands, once.** The maintainer chose this so
  that the gradcap means completion from the first day. It is the one place
  where a stored bird changes after it is drawn, and it changes one slot only.
  The migration `SwapStarterGradcapForHeadband` does it. It is a migration, not
  a rule in `ensureSpec`, because a rule in `ensureSpec` would also take away a
  gradcap that a student EARNED later.

The headband is a band across the forehead, tied at the right side. It does
not hide the tuft. It covers part of the brows on `curious`, `keen` and
`startled`; those expressions still read, because since the tune-up they
differ mainly by eye shape.

### 5. What a student sees on other pages

| Surface | Border | Backdrop |
|---|---|---|
| Account page | yes | yes |
| Instructor roster | yes | yes |
| Leaderboard | yes | yes |

Both are lateral: a moss ring is not better than a honey ring. So both may show
anywhere. A trophy never shows outside the account page.

---

## The picker (W1)

One page section on the account page, "Your chickadee":

- The bird at the standard size, as a preview.
- Two groups of colour choices: **Backdrop** (eight) and **Border** (none plus
  five). Each choice is a radio input with a round colour swatch, so the form
  works with the keyboard and with no JavaScript.
- One **Save** button. The form posts to `POST /account/avatar`.

Each choice shows its name under the sample, so a reader who cannot tell two
colours apart can still choose. The checked choice has a ring and a bold name.

With JavaScript, `Public/avatar-picker.js` updates the bird in the Account
info section as soon as a choice changes (a live preview). It sets only the two
custom properties, `--av-backdrop` and `--av-border`, which the UI rules allow
("JS does not make styling decisions"). Each radio input carries the token name
in a data attribute, so the script holds no palette. Nothing is saved until the
student presses Save.

The style guard counted every `.style.<property>` write, including a
custom-property write, so the preview first looked impossible. The guard now
exempts `.style.setProperty('--…')`, which is the pattern the UI rules already
named as the right one.

---

## Ideas for later slices

These are ideas, not commitments. Every item must obey the sprite rules: flat
closed paths, colour from a class, no gradient, filter, mask or clip-path.

**Borders.** Ring styles (dashed "stitched", double), seasonal rings (maple
leaves in the Fall term, snowflakes in the Winter term), and a laurel ring for
course completion.

**Accessories with a meaning in a programming course.**

| Item | Idea | A possible way to earn it |
|---|---|---|
| Rubber duck beside the bird | debugging | the comeback signal (`gradeJumpPercent`) |
| Magnifying glass | testing and assertions | an achievement on an assertion section |
| Infinity pendant | loops | a loop-concept achievement |
| Nesting doll | recursion | a recursion-concept achievement |
| Gradcap | completion | a course-completion or cumulative achievement |

**Accessories for fun.** Pencil behind the ear, coffee cup, small laptop,
bandana, party hat.

**Other slots.** A perch (a branch under the bird), backdrop patterns (dots,
stripes), and a pin that shows one trophy (account page only, too small below
48px).

**Trophy case.** Class-activity medals, record titles, concept-mastery badges,
and labs completed.

---

## How earning will connect to the platform (planned)

- **Slots.** The one accessory field becomes slots: head, face, neck, side,
  border, pin. There is one item per slot, so conflicts are rules per slot (the
  `hidesTuft` shape). The migration uses `decodeIfPresent`, as the tune-up did.
- **Catalogue.** A `WardrobeItem` list in code, append-only, with an unlock rule
  per item: `starter`, `achievement`, or `term(season)`. A drift test checks the
  sprite and the catalogue in both directions.
- **Unlocks are stored and sticky.** Individual badges are computed at render
  time today (`earnedIndividualBadges`) and never stored. An unlock must not
  disappear after a regrade, so it needs its own table:
  `wardrobe_unlocks` (user, item, source, time).
- **Achievements grant items.** A new reward type, `unlock(itemID)`, beside
  `badge`, `title` and `points`. Instructors then write "80% on Lab 6 in two
  attempts unlocks the magnifying glass" in the editor and through MCP
  `update_achievements`, with the conditions that exist today. The MCP prose
  must derive the item list from the catalogue, as the language lists do.
- **Evaluate outside the grading path.** Grant unlocks in the achievement sweep
  or lazily when the account page loads, never while a result is written. A
  cosmetic must not be able to fail a grade.
- **Mastery across assignments** ("mastered loops" over several labs) needs a
  course-level concept tag. Achievements are per assignment today. The cheap
  first version is one achievement per lab on a "Loops" suite section.

---

## Shelved: a participation currency

The idea: students earn points for engagement (a first graded submission, a
grade over a threshold, a submission before the deadline, a high place in a
class activity) and spend them on wardrobe items. The points are never grades.

The maintainer shelved it. The name "seeds" was not fun enough, and the
wardrobe must work first. What we learned is kept here for when it comes back:

- **Never reward the number of submissions.** That rewards spam, and every
  submission costs runner time.
- The slip-day bank (`APISlipDaySpend`) is the pattern: ledger rows with a
  unique idempotency key, and the balance is their sum.
- Keep one wallet per account, earned per course, because unlocks are
  account-wide (decision 5 in student-avatars.md).
- The name must not collide with grades. `RewardType.points` already means a
  grade bonus.
- A balance is private. It never shows on a leaderboard.

---

## Privacy and compliance

- The border is part of the stored spec, so `/account/export` already carries
  it in `profile.json`, and deletion already cascades.
- Nothing here enters BrightSpace sync, LTI grade passback or any grade.
- No new environment variables.

---

## Slice plan

| Slice | Content | Status |
|---|---|---|
| W1 | Border + backdrop picker on the account page; headband replaces the gradcap in the draw; existing gradcaps swapped | in progress |
| W2 | Ring styles (dashed, double) | planned |
| W3 | `wardrobe_unlocks` + the `unlock(itemID)` achievement reward; the three unlockable expressions become grantable | planned |
| W4 | Slots and the first earned accessories (gradcap for completion, rubber duck) | planned |
| W5 | Trophy case + class-activity medals | planned |
| — | Participation currency | shelved |
