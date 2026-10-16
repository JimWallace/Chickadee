# Student wardrobe — design note

**Status:** slice W1 (border and backdrop colour, chosen on the account page),
slice W2 (rings as sprite art, the patterned rings and the staff ring) and the
seasonal rings (W2b, 0.5.309) have shipped, and so has a small W3: three
items a student earns by their own graded work (#2592, "Earned items" below).
The design pass on earning (#2603) is decided: see "Earning: the design pass"
below, which replaces the earlier plan where they differ. The participation
currency is **shelved**: the maintainer decided that the first idea for it
("seeds") is not fun enough, and we will come back to it.

This note continues [student-avatars.md](student-avatars.md). Read decisions 2
and 5 there first: the spec is stored and drawn once, unlocks are account-wide,
and the wardrobe is lateral.

---

## What this is for

Students get small cosmetic choices for their bird. The purpose is to make
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

### 2. The ring is a sprite layer

The border is drawn as a ring: the seventh `<use>` of the bird, the symbol
`av-ring-<ring>`, after the tilt group so that it does not tilt. W1 drew it as
a CSS `outline` on the avatar element. W2 replaced the outline, because the
rings we plan next (patterned, seasonal, a laurel) are art, and `outline-style`
cannot draw any of them. One mechanism for every ring is simpler than a CSS
ring for plain colours and art for the rest.

- `AvatarBorder` is what a student stores. `AvatarRing` is the art. Each
  border maps to one ring: the five colours map to `solid`, and each patterned
  border maps to its own ring. `staff` is a ring that no border maps to (see
  "The staff ring").
- Every ring obeys the sprite rules. The rings are closed annulus sectors
  between radius 28.8 and 32 (the disc is 32), so no fill-rule and no stroke
  is needed.
- The solid ring is filled from `--av-border`, the per-student custom property
  from W1. The patterned rings use their own classes or the bird's own
  `--av-accent` and `--av-cap`.
- "No border" is the ring `none`, an empty symbol. A bird with no border is
  exactly the bird it was before borders existed. (A first version used the
  backdrop colour for "none". That was wrong: an opaque ring in the backdrop
  colour covers the outer band of the disc, and the scarf tail and the beanie
  pom reach into it.)

A ring is inside the disc and is drawn last, so it paints over the outer band.
A hat or a scarf that reaches the edge goes under the ring. This looks like the
bird is in a frame.

`.avatar` sets `forced-color-adjust: none`. The bird is decorative and its
colours are the student's; without this, forced-colors mode repaints the bird
and draws the transparent ring in the system colour.

### 3. One chokepoint validates every change

`AvatarCustomization` (Core) is the only thing that applies a student's choice
to a spec. It lists the slots a student may change and the options that are
open to them. It is also the one place that checks unlocks (`isOpen` and
`applying` take the student's earned `WardrobeItem`s), in the same shape as
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
`intrigued`; those expressions still read, because since the tune-up they
differ mainly by eye shape.

### 5. What a student sees on other pages

| Surface | Border | Backdrop |
|---|---|---|
| Account page | yes | yes |
| Instructor roster | yes | yes |
| Leaderboard | yes | yes |

Both are lateral: a moss ring is not better than a honey ring. So both may show
anywhere. A trophy never shows outside the account page.

On the roster and the leaderboard, course staff wear the staff ring in place
of their chosen ring (see "The staff ring").

### 6. Rings have tiers: starter, earned and special

`AvatarBorder.availability` gives each ring a tier. The tier says how a student
gets the ring. It is not a rank.

| Ring | Tier | Art |
|---|---|---|
| none, and the five solid colours | starter | one band in the chosen accent |
| rainbow | starter | six bands, red to violet |
| two-tone | earned | half in the bird's accent, half in its cap colour |
| stitched | earned | the accent with 24 cream stitches |
| spectrum | special | five bands in the five accent colours |
| snowflake, shown as "Winter" | seasonal (Winter) | a ramp from ice blue at the top to indigo at the bottom |
| blossom, shown as "Spring" | seasonal (Spring) | a ramp from blossom pink to apricot to new-leaf green |
| maple, shown as "Fall" | seasonal (Fall) | a ramp from gold to orange to brick to maroon |
| the six concept rings | earned | see "Concept rings" below |

Rainbow is a starter on purpose. It is also the Pride flag, and a student must
not have to earn a way to show it.

Two-tone uses the bird's own colours. When the accent and the cap are near the
same hue, the ring reads as one colour. The student chooses the accent, so the
student can fix this. We tried two other shapes (cream segments, and a cream
stripe inside the accent). The segments lost the edge of the disc on a pale
backdrop, and the stripe made two thin lines, which is the shape of the staff
ring.

A locked earned or special ring is listed under "Not open yet", as an item
and not as an input, with "earned" in the name, so that a student can see
what there is to earn. **The design pass (#2603) removes this list:** a
locked item does not show at all (see "Earning: the design pass", E3). When a rule earns it, the name says how ("Two-tone ·
earned when every test passes on three assignments"); stitched and spectrum
have no rule yet ("Stitched · earned"). `AvatarCustomization` refuses a
locked ring, so a hand-made request cannot choose one.

**Concept rings.** Six earned rings, one for each lab concept. They are
lateral: different, not better. The raw value is the sprite name
(`av-ring-<raw value>`).

| Raw value | Display name | Art | Concept |
|---|---|---|---|
| `lifering` | Life ring | A red and white life ring with rope wraps: a float | Variables & numbers |
| `greenlight` | Green light | A green band, with a traffic light at the bottom and the green lamp lit | Conditionals |
| `ouroboros` | Ouroboros | A snake that eats its tail (`while True:`), head at the lower left | Loops |
| `function` | Function | The ring broken into a tapered `(` and `)` | Functions |
| `binary` | Binary | Eight dashes, long for 1 and short for 0, that spell 230 clockwise from the top | Data representation |
| `pulse` | Pulse | A solid band with one ECG trace (P, QRS, T) at the lower right | Health data |

- **Three rings are wider, inward only.** The usual band is r 28.8 to 32.
  The ouroboros head goes in to r 25.6, the green light housing to r 25.4,
  and the life ring to r 25.6 all the way round. Nothing goes past r 32. At
  36 and 96 px, at all three tilts, none of the three touches the eyes or the
  beak.
- **Contrast applies to the band colours only.** `--avatar-function`,
  `--avatar-binary`, `--avatar-pulse`, `--avatar-ouroboros-body`,
  `--avatar-greenlight-band`, `--avatar-lifering-red` and
  `--avatar-lifering-rim` hold the term-ring floors (1.45:1 light, 1.8:1
  dark). The lamps, the rope, the snake's back pattern and the white
  quarters are exempt. The snake's eye uses the bird's own `.av-eyewhite`
  and `.av-pupil`. The white quarters rely on the rim to
  separate them from a light backdrop. The rim was lifted from the design's
  `#8E2A20` to `#AB3327` (same hue), because the design value gave only
  1.40:1 on the dark sky backdrop. No dark mirror.
- **Earned on a tagged lab.** An instructor tags an assignment with a concept
  (`AssignmentConcept`) in the "Wardrobe ring" select under Student Options
  on the edit page, or through MCP `set_assignment_concept`. A student who passes every test on a tagged assignment
  earns that concept's ring. The tag is optional, and several assignments may
  share one concept. A clone and a course bundle keep the tag. This is the
  first wardrobe rule that needs instructor setup. Nothing infers the concept from a title or an order.

### 6b. Earned items (a small W3, #2592)

These items are earned by a student's own graded work (`WardrobeItem` in
Core, the rules in `WardrobeItem.earned(by:)`). Only the concept rings need
instructor setup: the concept tag on an assignment.

| Item | Earned by |
|---|---|
| `chirp` face | the first graded submission |
| `sly` face | a first attempt on which every test it ran passes |
| two-tone ring | every test passing on three different assignments |
| `dreamy` face | a graded submission two days before the due date, on three assignments (#2603) |
| stitched ring | a comeback (every test passing after an attempt that did not) on three assignments (#2603) |
| a concept ring | every test passing on an assignment tagged with its concept |

- **Granted on the account page, never while grading.** `WardrobeUnlockStore`
  reads the student's own student-kind submissions that have a result, and
  stores what they earn in `wardrobe_unlocks` (user, item, time; unique per
  user and item). A cosmetic cannot fail a grade.
- **Sticky.** A stored unlock is never taken back, even when a regrade changes
  the result that earned it.
- **Browser results count.** A browser-graded result is built in the
  student's own browser, so a student who forges one could earn an item. The
  harm is cosmetic, and First-Try Perfect already trusts the same results;
  excluding them would leave most students nothing to earn.
- **Account-wide and lateral**, as every wardrobe item is.
- **In the export** (`profile.json`, `wardrobeUnlocks`) and removed with the
  account.
- Spectrum has no rule yet and stays locked until the achievement link
  exists (E7).

### 7. Seasonal rings

There is one seasonal ring for each Waterloo term: snowflake (Winter, January
to April), blossom (Spring, May to August) and maple (Fall, September to
December). `AvatarBorder.season` names the term, and the page shows the ring
by that name: "Winter", "Spring", "Fall". The raw values stay `snowflake`,
`blossom` and `maple`.

- **A student can choose it only during its term.** The term comes from
  today's date on the Waterloo calendar (`TermSeason.current()`), not from a
  course. Out of its term, the account page lists the ring under "Not open
  yet" with the month it opens ("Fall · opens in September"), and the
  chokepoint refuses it. In its term the ring is an open choice named "Fall".
- **A student keeps it after the term.** The stored ring is drawn on every
  date. The chokepoint always allows the ring the student already wears, so
  saving the form again in Winter does not take the maple ring away. This
  exception is for the worn ring only: it does not open any other ring.
- **The art is one colour ramp per term.** Each ring is eight flat steps,
  mirrored left and right and placed by height, so it shades from light at
  the top to deep at the bottom (`--avatar-winter-1` to `-8`, and the same for
  `spring` and `fall`). The earlier motifs (snowflakes, blossoms, maple
  leaves) broke up into specks at 36 to 48 px; a ramp reads as one band at
  every size. Segments overlap by 0.5 degrees, so no seam shows. Like the
  rainbow, the ramps have no dark-mode mirror. Every step holds at least
  1.45:1 against each light backdrop and 1.8:1 against each dark one
  (`AvatarTermRingTests`).

### 8. The staff ring

Course staff (a TA or an instructor in the course) wear the staff ring. It is
not a choice, and staff cannot change it.

- **Where the role comes from.** On a course page (the roster, the
  leaderboard), the ring comes from the person's role in THAT course. On the
  account page and on the admin Users page there is no one course, so the ring
  means "staff in at least one course that is not archived"
  (`AvatarStore.courseStaff`): a TA whose offering has ended is a student again
  and chooses their own ring (#1756).
- **It is never stored.** `AvatarPresentation(for:size:accessibility:isStaff:)`
  draws it in place of the stored ring. The stored border is kept, so a TA who
  is a student in a later course gets their own ring back there.
- **It is reserved.** No `AvatarBorder` maps to `AvatarRing.staff`, and the
  chokepoint refuses every ring change from staff with `staffRingIsFixed`. Staff
  can still choose a backdrop.
- **It is visually distinct.** It is the only ring with two separate thin
  bands, and the only ring in `--avatar-staff-ring`: a dark ink that is none of
  the student colours, with a light mirror in dark mode. A test checks both
  facts.
- **It does not replace the role chip.** The chip is searchable and a screen
  reader reads it. The ring is a second, visual signal.

---

## The "Your bird" card (W1, as changed by avatar-species.md decision 5 and #2588)

One page section on the account page, "Your bird", one card:

- The bird at the podium size (10rem), with its species name. The bird is no
  longer in Account info.
- Three groups of choices: **Face** (the starter expressions, each option
  the student's own bird wearing that face, then the unlockable faces under
  "Not open yet"), **Backdrop** (the eight backdrops) and **Ring** (the rings
  open now: none, the five colours, rainbow, and the seasonal ring of the
  term). Each choice is a radio input with a round sample, so the form works
  with the keyboard and with no JavaScript. A ring's sample is the ring
  itself, drawn from the sprite on the student's backdrop. The faces and
  rings not open yet follow under "Not open yet" as plain items, not inputs.
  Staff see the staff ring and a note in place of the Ring group.
- One **Save** button. The form posts to `POST /account/avatar`.

There is no species or colour group. The species, the colours and the
markings come with the bird (avatar-species.md, decision 5).

Each face and ring shows its name under the sample, so a reader who
cannot tell two colours apart can still choose. The checked choice has an
outline and a bold name. A backdrop's name is for screen readers only.

With JavaScript, `Public/avatar-picker.js` updates the card's bird as soon
as a choice changes (a live preview), and keeps Save disabled and "Undo
changes" hidden until a choice changes. It sets only
custom properties, `--av-backdrop` and `--av-border`, which the UI rules
allow ("JS does not make styling decisions"), and points the ring layer (the
`use` element marked `data-av-ring`) and the face layer at the checked
symbols. Each radio input carries its token names and symbol references in
data attributes, so the script holds no palette, no ring list and no face
list. Nothing is saved until
the student presses Save.

The style guard counted every `.style.<property>` write, including a
custom-property write, so the preview first looked impossible. The guard now
exempts `.style.setProperty('--…')`, which is the pattern the UI rules already
named as the right one.

---

## Earning: the design pass (#2603)

The maintainer decided these points in October 2026. Where they differ from
an earlier section of this note, they replace it.

### E1. Items are surprises

A student does not see a map of what there is to earn. The account page
shows only the items that the student can choose now. It shows no locked
item, no rule and no progress count. Students collect items organically
during the term, and each student has a different set.

The reasons:

- A list of locked items with rules reads as a list of goals. A student who
  cannot reach a goal can feel that they fail. The wardrobe must never do
  that.
- The account page must not fill with text.

### E2. After a student earns an item, the page says how

An earned item says how the student earned it, in the past tense: "Stitched:
earned for a comeback on three assignments". Before the student earns it,
nothing says that the item exists. This rewards the student, and it gives
students a reason to talk to each other about their birds.

### E3. Every item that can show has a rule

Because a locked item does not show, an item with no rule is simply not seen.
The "· earned" label goes away with the "Not open yet" list. The seasonal ring
of another term is the one exception: every student gets it, so "Fall · opens
in September" stays. It shows no failure.

### E4. What we reward

The rules reward effort, habits, persistence and correctness, so that a
student who starts with less experience still collects items. Each rule counts
**different assignments**, never submissions: a count of submissions rewards
spam, and each submission costs runner time.

| Item | Rule | Kind |
|---|---|---|
| `chirp` face | a first graded submission | effort |
| `sly` face | every test passes on a first attempt | correctness |
| two-tone ring | every test passes on three assignments | correctness |
| `dreamy` face | a graded submission at least 48 hours before the due date, on three assignments | habit |
| stitched ring | every test passes after an earlier attempt that did not, on three assignments | persistence |
| spectrum ring | no rule; hidden until the achievement link (E7) | — |
| concept rings | every test passes on linked assignments (E6) | mastery |

The early rule reads the server's submission time and the assignment's own
due date, not a student's extension, so a student cannot forge it. An
assignment with no due date does not count for it. An early submission counts
whatever its result: the rule rewards the habit, not the grade.

### E5. Pace across a term

For a steady student: about one item by week 2, two or three by week 6, and
four or five by the end of the term. A strong student has the built-in items
by mid-term. Each threshold is a named constant. A Core test runs three
synthetic students (strong, steady, struggling) through the rules and checks
these targets.

### E6. Concept-mastery items, linked by an instructor

Some items mark mastery of a concept: loops, conditionals, recursion. The
concepts are a fixed list in code, append-only. Each concept owns one item. An
instructor links a concept to course content in the editor and through MCP;
this is authoring data, not student data. A student earns the item when every
test passes on the linked work. The design handoff draws these items as rings
(for example the ouroboros ring for loops), so they need no new slot.

### E7. Achievements: open

Achievements and badges stay a separate system for now. The result-page toast
(J3, [result-celebration.md](result-celebration.md)) shows both, in one card.
Whether an achievement can grant a wardrobe item is still open. One rule is
already fixed: an item that an achievement grants has no built-in rule, so the
"how you earned it" text is always true.

### E8. Per account

Items stay per account (student-avatars.md, decision 5). The rules count work
in all courses. A student in two courses collects faster. This is acceptable
for a cosmetic.

### E9. Instructor control

There are no switches for the built-in rules. They need no setup, and an item
is lateral, so a switch would have no purpose. An instructor's one control is
the concept link (E6). A course-only item is out of scope, because an
account-wide item would carry it into other courses.

### E10. Trust

Every rule reads the same result rows as First-Try Perfect, or a server time.
A forged browser result can give only a cosmetic item. This is acceptable for
each rule above, and every new rule must say the same in its issue.

### E11. A student finds out on the result page

When a result page loads, it grants what the student has earned, off the
grading path, as the account page does. A new item shows in the Earned toast
on that page, with the bird wearing it and a **Wear it** button. The design is
in [result-celebration.md](result-celebration.md), slices J1 to J3.

---

## Ideas for later slices

These are ideas, not commitments. Every item must obey the sprite rules: flat
closed paths, colour from a class, no gradient, filter, mask or clip-path.

**Rings.** A laurel ring for course completion. Each is one new
`AvatarBorder` case (appended), one `AvatarRing` case and one sprite symbol.

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
| W1 | Border + backdrop picker on the account page; headband replaces the gradcap in the draw; existing gradcaps swapped | shipped |
| W2 | Rings as sprite art; rainbow (starter), two-tone and stitched (earned), spectrum (special); the staff ring | shipped |
| W2b | Seasonal rings: snowflake, blossom and maple, open during their term and kept after | shipped |
| W3 (small) | `wardrobe_unlocks`; three items earned by a student's own graded work (#2592) | shipped |
| J1 | The result-page celebration: the bird at 56px, the 100% moment, the Improved and Already-100% states ([result-celebration.md](result-celebration.md), #2608) | shipped |
| E-b | The `dreamy` and stitched rules and the pace test (E4, E5, #2608) | shipped |
| E-a | Hide locked items; say how an item was earned after it is earned (E1 to E3) | #2615 |
| C1, C2 | Concept rings, and the instructor's concept link on an assignment (E6) | #2605, #2607 |
| J1b | The reduced-motion banner for a 100% result | #2618 |
| J2 | The Earned toast for wardrobe items (E11) | #2616 |
| J3 | One toast for everything earned, achievements included | #2617 |
| E7 | Design: can an achievement grant a wardrobe item? | #2619 |
| W4 | Slots and the first earned accessories (gradcap for completion, rubber duck) | #2620 |
| W5 | Trophy case + class-activity medals | #2621 |
| — | Participation currency | shelved |
