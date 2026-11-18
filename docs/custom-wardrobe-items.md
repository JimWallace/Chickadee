# Custom wardrobe items — design note

**Status: proposed.** The maintainer took four decisions on 2026-11-12 (see
"Decisions taken" at the end). Nothing in this note is built yet.

This note continues [achievement-rewards.md](achievement-rewards.md), whose
slice S2 lets an assignment achievement grant a wardrobe item, and
[student-wardrobe.md](student-wardrobe.md), which defines the wardrobe. Read
decision 4 of the first and decisions 2 and 6 of the second before this one.

---

## What this is for

S2 lets an achievement grant an item, but every item is still written in
code: an enum case, a sprite symbol and a stylesheet rule. A new ring is a
pull request. The Cross-fade ring for the HLTH 230 activity "The Class Paints
a Picture" (#3004) took one.

The maintainer wants course instructors to make their own unlockables: a ring
for each class activity in a term, and later faces, backdrops and wearables.
Cross-fade is the pilot case. This note makes an item **data**, owned by one
course offering, that an instructor defines and that the course's
achievements grant.

---

## Decisions

### 1. An instructor composes an item; they do not draw it

An instructor item is a **template** plus **paints** plus a **name**:

- The template is a shape the site already draws, one sprite symbol per
  template. A ring template is "solid", "halves", "ramp" (two to eight steps,
  in a chosen direction) or "bands" (two to six equal segments).
- The paints fill the template's parts, one paint per part.
- The name is what the student reads in the picker: "Cross-fade".

The alternative is an uploaded SVG. It is rejected for three reasons. It is
active content on a page every student loads. It cannot be checked for size,
for contrast or for reaching into the bird. And it would end the one rule
the bird holds today: the geometry lives once, in
`Resources/Sprites/avatar-sprite.svg`.

### 2. Paints come from one site palette, never free hex

Every colour a bird draws is a stylesheet token. `AvatarMarkup` emits token
names, and `check-styles.sh` allows an inline style only when it assigns a
custom property, so no hex value ever reaches a page from data. An
instructor item keeps that rule: a paint is a **palette name**, one of a
fixed set of tokens, `--avatar-paint-<name>`, declared once in
`Public/styles.css`.

The palette is large enough to compose with: about forty colours, in hue
families, each in a light and a deep step. A test holds every paint to the
ring contrast floors that the built-in rings already meet: at least 1.45:1
against every light backdrop and 1.8:1 against every dark one
(`AvatarTermRingTests`). So **a saved item is visible by construction**. The
save checks names, not colours, and no instructor can make a ring that
disappears.

Free hex was considered. It would need a save-time contrast check, a dark-mode
rule for each colour, and an exception in the style guard. A palette needs
none of these.

A new paint is a pull request, as a new template is. Both are rare: the
palette and the templates are the vocabulary, and instructors write in it.

### 3. Every slot, through one model

The model is the same for every slot the bird has, now and later. What
differs per slot is the template catalogue and what a part may be painted
with:

| Slot | Templates | Paints | First slice |
|---|---|---|---|
| ring | solid, halves, ramp, bands | ring paints (decision 2) | C1 |
| backdrop | the disc | a backdrop pair: a light and a dark paint, from a backdrop palette at the backdrops' lightness | C4 |
| face | a pool of instructor-grantable faces, site art | none: a face is geometry | C5 |
| wearable | a pool of instructor-grantable accessories, site art | the accessory's accent part, from the accent palette | C5 |

A face has no colour to vary, so a face template is a whole face from a pool
the site ships for instructors to grant. It is not one of the starter or
rule faces. The pool is how a course gets a face of its own without drawing
one. A wearable is the same, with an accent that the instructor paints.

The slot is a field of the item, not a type of its own, so the editor, the
MCP tools and the grant path are written once. A ring is the `border` slot
and a face the `expression` slot of `AvatarCustomizableSlot`; a wearable has
no slot yet, and C5 adds it.

### 4. Items belong to a course offering; wearing is account-wide

An item is defined in one offering, such as HLTH 230-W27, and only that
offering's achievements can grant it. Once earned, it is worn everywhere, as
every wardrobe item is (student-avatars.md, decision 5;
achievement-rewards.md, decision 4.2). A student in HLTH 230 who earns
Cross-fade wears it in CS 136.

This answers "HLTH 230 only" for the place an item is earned, which is what
an instructor controls. It does not limit where it is worn: the bird is the
student's, not the course's.

### 5. A worn item is copied into the bird

A bird is drawn on many pages: leaderboards, rosters, the composite, the
favicon. None of them should read a course's item table to draw one.

So when a student puts an item on, the template and the paints are **copied
into their spec**: `AvatarSpec` gains `customRing` (and later
`customBackdrop` and the others), decoded with `decodeIfPresent`. When it is
set, it overrides `border` for drawing only: `border` keeps its stored value,
and the hatch and the seed generator leave both fields as they are. The
presentation draws the template's symbol and sets one `--av-paint-N`
custom property per part, to the palette tokens. The names follow the
existing split: `--avatar-*` tokens hold the palette, `--av-*` properties
are set per bird. `AvatarInlineProperty` grows from its fixed list to carry
one property per part.
Every page that draws a bird today draws a custom ring with no new read.

The copy is also what makes an item **sticky**. If the instructor changes
the item, renames it or deletes it, or the course is deleted, a student who
earned it keeps the item as they earned it. That is the rule for every
earned item today. The unlock row stores the same copy, so the picker can
still offer an item the course no longer has.

### 6. Who can do what

| Action | Who | Why |
|---|---|---|
| Create, edit or delete a course's items | instructor of the course (decided) | An item reaches every page the student's bird appears on, in every course. |
| Choose an item as an achievement's reward | TA and above, as the achievements table is | The reward is part of the achievement, which TAs already author. |
| Read the item list | course staff | |

MCP follows the same gates. A TA's agent can attach an existing item to an
achievement and cannot create one.

### 7. Hidden until earned, as before

A course item follows achievement-rewards.md decision 5. A student sees no
locked item, no rule and no progress. The Earned toast names the achievement
("Earned for “Painted a tile”."), and the account page says how each one was
earned.

### 8. A new term copies the items (decided: the easiest)

The maintainer had no preference and asked for the easiest. The easiest
rule is to **copy the items with the course** when a new term is cloned
(`CourseCloneService`) and when a course bundle is imported. The reason is
that the assignments already carry their achievements in the manifest. A
cloned activity whose achievement grants "Cross-fade" needs a "Cross-fade"
in the new offering to grant. Copying keeps them paired with no remap step
for the instructor.

A copied item is a new item of the new offering. A student who earned the
W27 item and earns the W28 one holds two unlocks of one look: the unique
index is on the item, not the look, so the picker removes the duplicate.

### 9. Built-in grantable items stay

`WardrobeItem.grantable` (Spectrum, Cross-fade) stays. Every course can
grant those two, and each course can add its own. Cross-fade keeps its
built-in art: re-expressing it as a ramp item would draw the same ring and
gain nothing.

---

## Model

Core:

- `CustomWardrobeItem`: `id` (UUID), `slot` (`AvatarCustomizableSlot`, plus
  the wearable slot when C5 adds one), `template` (a per-slot enum, such as
  `CustomRingTemplate`), `paints` (`[AvatarPaint]`), `name`. Validated by
  `throws(CustomWardrobeItemError)`: the template exists for the slot, the
  paint count matches the template's parts, every paint exists, and the name
  is 1 to 40 characters.
- `AvatarPaint`: a `CaseIterable` enum whose raw value names the token. The
  palette test iterates it.
- `CustomRingTemplate`: `solid`, `halves`, `ramp(steps:direction:)`,
  `bands(count:)`. One sprite symbol per concrete shape (`av-ring-ramp8-lr`
  and so on), named by the template. A new test checks that every template
  has its symbol and every symbol a template, in both directions.
- `AvatarSpec.customRing: CustomRingLook?`, the copy (template and paints,
  no name).
- `AchievementReward.item` accepts `custom:<uuid>` beside a `WardrobeItem`
  raw value.

Server:

- `course_wardrobe_items`: `id`, `course_id` (FK, cascade), `slot`,
  `template`, `paints_json`, `name`, `created_at`, `updated_at`.
- `wardrobe_unlocks` gains `look_json`, the copy (decision 5). The `item`
  column holds `custom:<uuid>` for a course item, so the unique index still
  stores an item once.
- The grant (`AchievementAwardStore.grantWardrobeRewards`) resolves
  `custom:<uuid>` against the achievement's own course and refuses an item of
  any other course. A manifest cloned into another course keeps the row and
  grants nothing until the item is copied (decision 8).
- The save validator refuses a reward that names an item the assignment's
  course does not have.

---

## Surfaces

- **The course Achievements tab** gains a **Wardrobe** section for
  instructors. It shows the course's items, each as a swatch on the
  instructor's own bird, with Add, Edit and Delete. The editor picks a slot
  and a template, then one paint per part from the palette, with a live
  preview of the bird wearing the item. `ui-review` checks it.
- **The assignment Achievements editor's Item select** lists the built-in
  grantable items, then this course's items, by name.
- **The account page** offers an earned course item among the rings and says
  how it was earned, as S2 does.
- **MCP:** `get_course_wardrobe` (`content:read`) and `update_course_wardrobe`
  (`content:write`, instructor only), replacing the list wholesale like the
  other list tools. The palette and the templates are derived prose with a
  coverage test, as the grantable items are (`MCPWardrobeItemProse`). The
  reward field takes `custom:<uuid>`. Update `MCPToolCatalog.live`, the
  instructions and the sync suites.

---

## What this does not do

- No uploaded art, and no free colours (decisions 1 and 2).
- No item that changes what a student can do. The wardrobe stays lateral and
  cosmetic.
- No per-course wearing. An earned item is worn everywhere (decision 4).
- No new environment variable.
- No MCP tool reports who earned an item. That is student data
  (achievement-rewards.md, S5).

---

## Slices

Each slice is one PR. Each leaves `main` green and every existing bird as it
is.

| Slice | Content | Depends on |
|---|---|---|
| C1 | The ring palette and the ring templates (sprite symbols, tokens and their tests); `CustomWardrobeItem` for rings; `course_wardrobe_items`; `AvatarSpec.customRing` and its presentation; `wardrobe_unlocks.look_json`; the grant and the picker for a course ring. No authoring surface: tests seed items. | S2 (shipped) |
| C2 | MCP: `get_course_wardrobe`, `update_course_wardrobe`, `custom:<uuid>` in the reward field. The HLTH 230 activity rings can be authored from here. | C1 |
| C3 | The Wardrobe section of the course Achievements tab, and the Item select's course group. `ui-review`. | C1 |
| C4 | Backdrops: the backdrop palette (light and dark pairs) and `customBackdrop`. | C1 |
| C5 | Faces and wearables from instructor-grantable pools. This waits for the wearable slot (W4, #2620). | C1 |
| C6 | New term and bundle import copy the items (decision 8). | C1 |

C2 is the shortest route to the maintainer's goal of a ring per class
activity, authored by an agent. C3 gives instructors the same thing without
one.

---

## Decisions taken

The maintainer answered on 2026-11-12.

| Question | Decision |
|---|---|
| Merge S2 with the built-in Cross-fade | Yes: merged as #3004. Cross-fade stays built in (decision 9). |
| Who creates items | Instructors only (decision 6). |
| A new term | No preference; the easiest, which is copying with the course (decision 8). |
| Which slots | All of them: rings, backdrops, faces, and wearables and other customizations when they exist (decision 3). |
