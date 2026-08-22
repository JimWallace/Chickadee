# Student avatars — design note

**Status: shipped for the account page.** Every student has a chickadee and a
per-course handle, drawn on first view and stored; the account page renders the
bird in place of the initials monogram, which is gone.

**Nothing displays either one to anybody else yet.** There is no leaderboard and
no class-facing page — `account.leaf` is the only template that renders a bird
or names a handle, and it shows a student only their own. The handle is
therefore **reserved, not in use**, and student-facing copy must say so: a
sentence about how a pseudonym behaves in front of classmates is a claim about a
surface that does not exist, and a student can act on it. Also not built: the
customization wardrobe (unlock model, picker) and the geometry slots it needs.

---

## What this is for

Two jobs, and it is worth keeping them apart because they pull in different
directions.

1. **Identity on the account page.** Today that is a two-letter monogram over a
   green circle. `AccountContext.monogram`'s own comment records why: no IdP
   claim in play releases a photo, and adding one would be a new claim, a new
   column and a privacy conversation. A generated chickadee is the answer that
   needs none of those.

2. **Pseudonymous identity on leaderboards.** Leaderboards do not exist yet —
   `docs/achievements-audit-2026-07.md` lists "surface record holders (opt-in,
   first-name-or-anonymous)" as an open design follow-up, and a class ranking
   listing real names is not something we would ship. The requirement is
   precise: **a student must be able to find themselves in the list and nobody
   else.** That is not "hide the names"; it is "give every student a handle
   they know and nobody else can compute."

Job 2 is the one with a correctness condition attached, so it drives the design.
Job 1 comes free once job 2 is solved.

---

## The constraint the art has to respect

The mascot (`Assets/chickadee-icon.png`) is a round, plush black-capped
chickadee: dark cap and bib, white cheek wrapping under the eye, buff flank,
dark wing folded over a pale belly. Those markings **are** the species read. A
generator that varies them freely produces twelve different birds and dissolves
the mascot — which is the opposite of the point, since the avatars are meant to
carry Chickadee's identity onto a page where the student's name does not appear.

So: **the silhouette and the cap/bib/cheek topology are fixed. Variation lives
inside them.** Every avatar is recognizably the same bird wearing a different
outfit. That is the Reddit-avatar model and it is the reason those read as one
family rather than as clip art.

---

## Reference class: identicon variety, Reddit wardrobe

The obvious comparables sit at opposite ends, and it is worth being explicit
about which end each half of this plan is at.

**GitHub identicons** are pure algorithm: a symmetric pixel grid, one hue, zero
art assets, zero customization. They cost nothing to build and nothing to
maintain, they are inoffensive because abstract shapes cannot compose into
anything, and nobody has ever felt anything about one. **Reddit's avatars** are
the other thing entirely: a layered character with a wardrobe, unlocks, and a
picker. That is where the fun is, and it is also where all the cost is — the art
library, the picker UI, and the judgement calls about what belongs in a wardrobe.

The lesson to take from the identicon end is not "be abstract". It is this:
**colour is free variation; art is expensive variation.** An identicon gets all
of its variety from colour and arrangement over one trivial shape vocabulary. A
chickadee can do the same — one silhouette, four or five painted regions, and
the palette does the work.

So the staging is: **day one is colour-driven, and the wardrobe is the second
act.** The first cut needs about six SVG shapes, not nine slots of costume, and
it still yields thousands of visibly distinct birds. Accessories, expressions
and tufts arrive later as the thing there is to earn — which is exactly what
they should be, since a cosmetic nobody had to unlock is just more art.

## Decisions

### 1. An avatar is a spec, not an image

`AvatarSpec` in `Core/` — `Codable`, `Sendable`, no Vapor — is a small struct of
enum slots. They split by what they cost, which is also the order they should
ship in.

| Axis | Options | Notes |
|---|---|---|
| `cap` | 8 | ink, slate, teal, forest, indigo, plum, rust, umber — the loudest axis, so it carries the least detail; it also picks the wing colour |
| `wing` | 6 | plain, barred, tipped, speckled, edged, twotone — symmetrical, both flanks from one drawing |
| `expression` | 6 | bright, sleepy, wink, curious, keen, startled — reads first and from furthest away |
| `accessory` | 8 × 5 accents | none, scarf, headphones, beanie, glasses, gradcap, bowtie, bloom |
| `backdrop` | 8 | sky, aqua, sage, straw, peach, rose, lilac, pebble — all near the same lightness so no bird shouts |

**8 × 6 × 6 × 8 × 5 × 8 = 92,160 distinct birds.** The accent multiplies: it is
part of the accessory axis, which is why the design writes it "8 + 5 accents"
and why 8 × 6 × 6 × 8 × 8 — 18,432 — is the wrong arithmetic.

**Body, cheek, beak and bib are NOT axes.** They are fixed, and they are what
keeps every bird a chickadee even when the cap goes plum. Cheek and flank were
axes in the first cut and stopped being them in the design pass: variation that
reaches the species read buys difference at the cost of family.

What matters is that the **stored artifact is the choice vector**, never rendered
bytes. Everything downstream follows: customization is mutating a slot, an unlock
is widening a slot's option set, rendering is a pure function of the spec, and
there is no image cache to invalidate, no storage bucket, and nothing to
regenerate when the art changes. Adding the geometry slots later is adding
fields with a default, not a migration of anybody's avatar.

### 2. The spec is stored, and drawn randomly on first use — not derived from identity

Two things this rules out, both deliberately.

**Never derive the avatar from the username, email, student ID, or display
name.** A hash of the username is reproducible by anyone who knows the username,
which means any classmate can compute a target's avatar offline and de-anonymize
the leaderboard in one step. This is the single failure that would make the
feature worse than showing names, because it would look private while not being
private. (It is also why Gravatar is not an option: the identifier there *is* an
email hash.)

**Do not store a seed and re-derive on every render**, which is what
`AssignmentSeedStore` does for personalization. That pattern is right when the
artifact must be re-derived by another process — the runner and the browser both
have to reproduce the same personalized inputs from
`CHICKADEE_ASSIGNMENT_SEED`. Nothing re-derives an avatar off-server. And
re-derivation carries a live hazard: with `index = seedBits % optionCount`,
appending one option to one slot reshuffles **every student's avatar**. Storing
the drawn spec makes the derivation a one-time function, so the option tables
can grow freely afterwards.

So: `avatar_spec` as a JSON column on the user row, materialized the first time
an avatar is needed, mutated in place by customization. A "reroll" is a fresh
draw. First-use materialization has the same race as `ensureSeed` and takes the
same shape — and the same warning applies about not doing it inside an enclosing
transaction.

### 3. Uniqueness is carried by a handle, not by the picture

The tempting move is a UNIQUE fingerprint on the spec. It does not survive
contact with the leaderboard, for a reason worth writing down: **uniqueness has
to hold at the granularity a viewer can actually distinguish, at the scope where
they see them side by side.** At 24px in a table row, beak shape and tuft are
invisible; what separates two rows is cap colour, flank tint, wing pattern,
accessory and backdrop — about 28k combinations — and on the
colour-only first cut, 2,304. A 300-student course draws from either with a
near-certain visible pair. Enforcing per-course
distinctness would then make an avatar depend on the roster, so it would change
when somebody drops. That is a bad trade for a cosmetic.

Instead, every enrollment carries a **handle**: an adjective + woodland-noun
pair, "Amber Thicket", "Quiet Cedar", drawn from curated lists and enforced
UNIQUE per course. The handle is the identity; the avatar is the glance. The
leaderboard shows both, so a micro-collision costs nothing — the two rows still
say different things.

The handle earns its place three more times over:

- **Accessibility.** On a leaderboard the avatar *is* the identity, so it needs a
  text equivalent; a decorative `aria-hidden` image would leave a screen-reader
  user with an unlabelled row. The handle is that label, and it is real text
  rather than a generated alt string.
- **Speech.** Students can say "I'm Quiet Cedar" out loud. A picture cannot be
  said.
- **Text contexts.** Anywhere a leaderboard is exported, sorted, or pasted into
  a discussion, the handle survives and the SVG does not.

Scope asymmetry, and it is deliberate: **the avatar is per user, the handle is
per (user, course).** A per-course handle is what makes UNIQUE-per-course
enforceable at enrollment time, and it keeps a student unlinkable across two
courses' leaderboards by name. The avatar being global is what lets cosmetic
unlocks follow a student between courses, which is the part that makes
gamification feel like it accumulates.

Curating the word lists is real work, not a lookup: adjective-noun generators
produce unfortunate pairs, and both lists need a pass for words that collide
with real names.

### 4. Rendered as layered SVG `use`, recoloured through design tokens

The repo's UI guards decide the mechanism here, and they decide it well.

`check-styles.sh` guard S4 fails on raw SVG path data in any template or in
`Public/*.js` — every icon lives once in the `_icons.leaf` sprite and call sites
reference it. So the chickadee parts go in a sprite as symbols (a separate
`_avatar-sprite.leaf`, included by the pages that render avatars rather than by
`base.leaf`, since most pages need none of it), and one avatar is a stack of
about eight `use` elements.

Colour comes from CSS custom properties set on the wrapping element —
`style="--av-cap: var(--avatar-slate); …"` — which is one of the two inline
forms the template guard permits, and is exactly the "JS sets a custom property,
never a colour" rule pointed at Leaf. The palette itself is `--avatar-*` tokens
declared in `Public/styles.css` with dark-mode mirrors, because
`check-design-tokens.sh` allows a raw hex only as a token declaration there. The
dark mirror should be a **tone** adjustment, not a hue change: the same student's
avatar has to stay the same bird in both themes.

That constraint is also a design gift. A bounded token palette produces a family
that reads as one system, which continuous HSL never does.

What this buys, concretely: no image pipeline, no PNG generation, no cache, no
CDN, no new bytes per student. Rendering is a table lookup and string
concatenation. Recolouring for dark mode is free and happens in CSS.

Swift builds the layer list and the custom-property string; `_avatar.leaf` takes
it as a sub-context (the bare-second-parameter `extend` form, not the labelled
`with:` form, which does not lex) and loops. Leaf makes no decisions.

**Two sizes.** The account page gets 3rem; a dense table gets `.avatar-sm` at
1.5rem. Drawing the bird settled what this is for, and it is not DOM weight:
the parts that never vary geometrically are baked into one `av-plumage` symbol,
so a whole bird is **five** `use` elements rather than one per feature, and 200
rows cost 1,000 nodes. The real reason for the small variant is legibility —
beak, bib and wing marks stop being separable somewhere under 24px — which is
the same fact that makes the handle, not the picture, the thing a leaderboard
identifies a student by.

### 5. Customization and unlocks

Each option carries an unlock rule: `starter` or `achievement(id)`. The initial
draw uses starter options only; achievements widen the pool. Saving a
customization validates the chosen slots against the student's unlocked set at
one chokepoint — the same shape as `evaluateCourseWrite`, one function that
every door goes through.

There is deliberately **no staff cosmetic**. A TA-only colourway is an
impersonation surface the moment a student's random draw lands near it, and role
already has a place in the UI — a chip beside a name, which says the thing
unambiguously and is searchable. (Impersonation between students is not a risk
worth engineering against: the handle is unique per course and cannot be chosen,
so a copied outfit still sits under a different name.)

Three consequences to accept up front:

- **Unlocks are account-global, not per-course.** A scarf earned in CS 135 is
  worn in CS 136. Per-course cosmetics would need per-course avatars, which
  decouples the avatar from the account page and loses the "that's me" property
  the whole feature exists for.
- **New options should arrive as unlockables, not as starters.** Adding a
  starter option is harmless once specs are materialized (decision 2), but a
  new unlockable is the version that gives someone something to earn.
- **Cosmetics must not rank.** On a leaderboard, an unlocked accessory is a
  public marker of what a student has earned — which means a bare avatar beside
  a decorated one publicly marks a student as having earned less. Keep the
  wardrobe *lateral*: a scarf is different from no scarf, not better than it,
  and there is no bronze/silver/gold tiering that turns the avatar into a second
  scoreboard inside the first. This is the one place where the gamification
  pressure and the pedagogy point in opposite directions, and the pedagogy wins.

The picker itself is one page section: the avatar at full size, one control per
slot, locked options shown locked rather than hidden — a student cannot chase a
badge they cannot see, which is the same note the achievements audit already
makes about unearned achievements.

### 6. Inoffensive by construction, not by moderation

There is no upload, no drawing surface, and no free text anywhere in an avatar,
so nothing a student can do produces something we did not ship. That reduces the
whole question to which options go in the tables — a review done once, at
authoring time, by a human. The rules that fall out:

- **No option that reads as a human skin tone.** The base is a bird, and body
  colours should be either bird-plausible or frankly artificial (teal, plum,
  rust). Generators built on human figures spend their lives managing this; a
  chickadee simply does not have the problem unless we introduce it.
- **No flags, uniforms, religious garments, or political signifiers.** Whimsy
  only. This is most of why Reddit's wardrobe is fantasy — it is not
  squeamishness, it is that a wardrobe with real-world referents needs a
  moderation policy and a wardrobe without one does not.
- **No text or glyphs in any layer**, which is the usual vector.
- **Review the overlaps, not the product.** 8.3M combinations cannot be
  eyeballed, but the slots that physically overlay each other — accessory × cap,
  accessory × backdrop — are a table of a few hundred, and that is where an
  unfortunate resemblance would come from. Review that table; the rest is
  independent.
- **The handle word lists get the same pass, and need it more.** Adjective-noun
  generators reliably produce unfortunate pairs, accidental real-world
  references, and words that collide with real names. Both lists want a
  deliberate review, and the pairing needs a blocklist rather than trust.

The point of listing these is that they are cheap when the tables are being
written and expensive afterwards, once students are wearing the results.

### 7. What drawing it actually taught

The art for the colour slots exists (`Resources/Views/_avatar-sprite.leaf`,
the `--avatar-*` palette in `Public/styles.css`, and
`Tools/avatar-preview/preview.mjs`, which renders a contact sheet from those two
files rather than from a copy of them). Nothing is wired: no `AvatarSpec`, no
column, no page renders one. What follows is what the drawing changed, since
four of the five findings were only visible by rendering the thing and looking
at it.

**A clipPath referenced from a symbol inside a `display:none` sprite silently
does not apply in Chromium.** The shape renders **unclipped** — a cap drawn as a
rectangle and trimmed to the head becomes a rectangle across the whole viewBox.
This cost two full iterations before it was diagnosed, and it is the single most
important thing in this section, because the failure is invisible to every kind
of test this repo has: the template resolves, the page renders, the CSS is
valid, and the picture is wrong. The icon sprite never hit it because stroked
glyphs reference nothing. **The sprite therefore uses no clip-path, mask,
filter or gradient at all**; every shape is a closed path that already follows
the body circle, which is more portable than depending on a browser quirk
resolving the way we like.

**The wing's outer edge has to BE the body arc.** As an inset ellipse it reads
as a dark blob floating on the belly; as a path whose outer boundary is the
silhouette, it reads as a folded wing. This is also what makes it clip-free:
the arc is in the path.

**The beak must be the lightest of a cap family's three tones.** Nature says a
chickadee's beak is dark, and a dark beak on a dark bib disappears completely in
flat vector — the whole centre of the face becomes one mass. Each cap family is
therefore a triple (cap, wing, beak) rather than one colour, with the beak a
clear step lighter than the wing.

**Horizontal bands read as a surgical mask.** Building the face as "cap on top,
belly at the bottom, cheek is whatever is left between them" produces a white
band spanning the silhouette edge to edge, and the eye reads it as a mask, not a
bird. The fix is topological: the cap wraps **down the sides** of the head and
the cheeks are two discrete patches punched into it, so no white ever reaches
the outline. That is also what the real bird looks like.

**The first cut yielded 9,216 birds** from colour alone — 8 caps × 4 cheeks × 6
flanks × 8 backdrops × 6 wings. The design pass replaced cheek and flank with
expression and accessory and took it to 92,160, which is the better trade: a
varying cheek changes what species the bird is, while an expression changes who
it is.

**Only the backdrops have dark-mode mirrors.** A pale disc behind the bird
glares on a dark page; the bird itself must be the same bird in both schemes, so
its own colours do not change between them.

**The bird is symmetrical: two wings, no tail.** The first cut was a
three-quarter bird with one folded wing and a tail wedge at the lower left,
following the mascot. It did not survive being looked at — at avatar sizes the
tail reads as a dart or a fin stuck to the side of a circle, and the single wing
makes the whole thing look like it is turning away. Reflecting the wing about
the body's vertical axis fixes both: the bird faces the viewer, the pale belly
sits between two wings, and the silhouette is a clean circle. This is also why
every avatar set worth copying is front-facing and symmetrical — asymmetry needs
more pixels than an avatar has to read as deliberate rather than as damage.

The reflection is a transform, not a second set of coordinates. An arc cannot be
mirrored by negating its x values alone; its sweep flag has to invert too, and
getting that wrong produces a curve that is subtly wrong in a way nobody will
look for. One drawing, mirrored by the renderer.

### 8. Seed to bird, bird to page

`Core/AvatarSpec.swift`, `Core/AvatarHandle.swift` and `Core/AvatarMarkup.swift`
are the model; `AvatarStore` materializes; `_avatar.leaf` renders.

```swift
let spec = AvatarSpec.drawn()                    // first use, system RNG
let spec = AvatarSpec.drawn(fromSeed: 12345)     // reproducible: tests, previews
let handle = AvatarHandle.make(excluding: taken) // unused in this course
AvatarPresentation(for: spec, size: .standard, accessibility: .decorative)
```

**There is deliberately no `svg(forSeed:)`.** It is the obvious convenience and
it is exactly the hazard decision 2 exists to prevent: a render path that takes
a seed re-derives on every render, and the day a slot gains an option every
student's bird changes. Drawing is a one-time act whose result is stored, so the
API keeps the two steps apart and gives the seeded draw a name that reads like a
fixture rather than a renderer.

**Swift emits token NAMES; the partial writes the markup.** An earlier cut had
Swift build the whole `<svg>` string. It cannot work here, for a reason worth
recording: `check-styles.sh` permits an inline style only when every declaration
is a custom-property assignment, and it reads templates statically, so a template
writing `style="#(someBlob)"` fails — correctly, since the guard cannot see
inside the blob. The alternative, rendering Swift-built markup raw, needs an
unsafe-HTML escape hatch this codebase uses nowhere and would hide the style
attribute from the guard entirely. Handing the partial the token names lets it
write real `--av-*:` declarations the guard can check, with neither side holding
a second copy of the palette.

Those seven `--av-*` properties are on the inline-custom-property allowlist in
`check-styles.sh`, alongside `--bar-h`, and for the same stated reason: each
carries a value that varies per **datum** — the student being rendered — which
no stylesheet can hold and no modifier class could enumerate 92,160 of.

**A standalone SVG** (an `<img>` src, a download, an email) is a different
function and is not written. It cannot reference the sprite or the stylesheet, so
it needs the path data and the hex values inline — and the only version worth
having reads both out of the files that already own them rather than re-holding
them in Swift.

**The Leaf trap this hit, which is the sub-context twin of the `isEmpty` one.**
`extend("_avatar", presentation)` makes the presentation the partial's **root**,
so its fields are addressed flat — `#(capToken)`, not `#(avatar.capToken)`. The
qualified form does not error: it resolves to the empty string, silently, and the
page renders a bird with no colours, no wing, and a 200. That is the same failure
shape as `#if(rows.isEmpty)` never firing, and the same lesson — a Leaf path that
cannot resolve is indistinguishable from one that resolves to nothing.
`AvatarSpecTests` now asserts the partial reads every field flat AND that none is
qualified, and the account-page test asserts no layer reference renders empty.

---

## What it costs — and what is stored

**Nothing stores a picture.** Three layers, and only the middle one is
persisted:

| | Lives where | Size | Per |
|---|---|---|---|
| Geometry | the sprite, inlined in the page | 6.0 KB, **2.4 KB gzipped** | page |
| Spec | a JSON column | ~60 bytes (five short strings) | student |
| Markup | built at render | 459 bytes | rendering |

Measured: building one avatar's markup costs **5.6 µs** and a draw costs 2.2 µs
(debug build — release is faster). A 200-row leaderboard is about 1.1 ms of
string interpolation, no I/O, and no image encoding anywhere. The 200 markup
strings are near-identical, so they gzip from 90 KB to **0.6 KB**.

**Why not store rendered SVG.** It would be a cache, and caches go stale. This
note's own history is the argument: the bird was redrawn once already — the
asymmetric tail came out — and because no bytes were stored, that cost nothing
and invalidated nothing. Stored images would also bake literal colours, which
kills the dark-mode backdrop, and would turn a customization click into a
re-render plus a write. On the wire it is worse too: a standalone SVG is ~2–3 KB
*per row* against one shared 2.4 KB sprite.

**Why not generate images.** There is no image pipeline at all — no PNG
encoding, no cache directory, no invalidation, no storage bucket. The browser
draws from the sprite, which is what browsers are for.

So: **store the choice, because it is random and must not change; do not store
the picture, because it is cheap and must stay free to change.**

The one honest caveat is that the sprite is inlined rather than fetched, so it
is not separately cacheable and costs its 2.4 KB on every avatar-bearing page
load. That follows the icon sprite deliberately: an external sprite is one more
fetch that can fail, and its failure mode is an avatar rendering as an empty
box. At this size the trade is not close.

**DOM** is the remaining number to take on a real page: five elements per bird,
so 1,000 for 200 rows.

---

## Privacy and compliance

- The avatar spec and the handle are personal information about a student, so
  they belong in the `/account/export` bundle and in the deletion path alongside
  everything else the export already covers.
- The handle→student mapping must be readable by course staff (a grading dispute
  needs it) and by nobody else. That is `requireCourseRole(atLeast: .ta)`, the
  existing chokepoint.
- **A stable pseudonym accumulates a behavioural trail.** Handle and avatar are
  constant across a term, so a leaderboard shows one pseudonym's performance over
  time. That is inherent to the feature, not a defect to engineer away — and a
  student who announces their own handle in a class chat has de-anonymized
  themselves. Say so in the student-facing copy rather than implying more privacy
  than the design provides.
- Leaderboard participation should be a course-level instructor setting from the
  first slice, and the audit's "opt-in" note suggests a per-student opt-out is
  worth pricing too.

### 9. What the design pass changed, and the two calls it did not get

A design pass arrived after the first cut shipped. Most of it is now the
feature: cheek and flank stopped being axes, expression and accessory became
them, the palette moved to the design's values, and the count went from 9,216 to
92,160. Two points were decided against the design, both deliberately.

**The seed is not an identity.** The design specified "real usernames hashed →
five indices; the same ID always returns the same bird". That is the failure
decision 2 exists to prevent: a bird derived from a username is reproducible by
anyone who knows the username, so a classmate can compute a target's avatar
offline and de-anonymise a leaderboard in one step. It looks private and is not.
The stored value is drawn from the system RNG and has no connection to who the
student is — which is also what makes a re-roll possible later, since there is
no identity to re-derive from. The visual result is identical; only the
derivation differs.

**The wings stay symmetrical.** The design specified "a single folded wing on
one flank, never a symmetric pair". At avatar sizes the asymmetric version reads
as a bird turning away, and the maintainer had already chosen the mirrored pair
for that reason. It stays a pair. The count is unaffected either way, since it
is the same six patterns.

**One consequence still owed:** the design's size floor — "the bird earns its
detail at 48px and up; below that the monogram chip takes over". `.avatar-sm`
was removed for that reason, since a 24px bird is a smudge. Nothing renders one
that small today, so the chip belongs to the slice that first needs it.

---

## Changing the art

The art is expected to move. What that costs, and what it cannot break:

1. **Edit `Resources/Views/_avatar-sprite.leaf`.** It is the only file with
   geometry. The body is a circle of radius 22 at (32, 35) in a 64×64 viewBox
   and every boundary is computed against it, so a change to the body means
   recomputing the cap, wing and belly edges rather than nudging them by eye.
2. **Look at it**: `node Tools/avatar-preview/preview.mjs > /tmp/avatars.html`
   renders a contact sheet — every cap family, every wing pattern, every cheek,
   flank and backdrop, and the size ladder down to 16px — from the sprite and
   the stylesheet rather than from a copy of either. Open it, or screenshot it
   headless. **Do not ship art you have not looked at**: four of the five
   findings in decision 7 were invisible in the source and obvious in a render.
3. **Keep the three sprite rules** in that file's header comment: no
   clip-path/mask/filter/gradient, colour from a class never an attribute, and
   boundaries computed against the body circle.
4. **What the guards will catch**: a symbol renamed away from an `AvatarWing`
   case, a palette token added or removed, a layer added or reordered without
   `layerSymbolIDs`, a `--av-*` property assigned in the partial that the
   presentation does not supply. What they will NOT catch is whether it looks
   right — hence step 2.

**Stored specs survive a redraw.** A spec names slots, not shapes, so
redrawing shared geometry changes what everyone's bird looks like without
shuffling whose is whose. The one change that is NOT free is reordering or
removing options within a slot: `AvatarCap.slate` must keep meaning slate. Add
to the end of a list; never renumber.

---

## Slice plan

Each slice is independently mergeable and independently useful.

- **S0 — the model. Done.** `AvatarSpec`, the five slot enums, the seeded draw,
  `AvatarPresentation`, the drift guards against the sprite and the palette, and
  `AvatarHandle` with its curated word lists — 80 adjectives × 80 nouns = 6,400
  handles, drawn without replacement within a course.
- **S1 — persistence. Done.** `users.avatar_spec` and
  `course_enrollments.avatar_handle` (`AddAvatarIdentity`), with a **partial**
  unique index on (course, handle) excluding NULL — without the exclusion the
  second enrollment created collides with the first on NULL. `AvatarStore`
  materializes both on first view, with the `ensureSeed` race shape. No
  backfill: nobody needs an avatar until a page renders one.
- **S2 — the account page, colour slots only.** The drawing half is **done**:
  eleven symbols, the `--avatar-*` tokens with dark mirrors, the
  component-vocabulary entry, and the contact-sheet tool. 92,160 birds. What
  the wiring is done too: `_avatar.leaf` takes an `AvatarPresentation`
  sub-context and the monogram is gone — the helper, the CSS, its
  component-vocabulary entry and its tests with it. Still owed: a
  visual-regression baseline, and a run of the `ui-review` agent, which is
  unconditional for anything touching `Resources/Views/` or `styles.css` and
  was unavailable in the environment this was built in.
- **S3 — student-facing copy and compliance. Done.** The account page names the
  handle per course and says plainly that a stable pseudonym is not anonymity.
  `profile.json` carries the spec and `enrollments.json` the handle, both
  described in the export's own README. The deletion path needed no work: both
  columns sit on rows that already cascade.
- **S4 — the wardrobe.** The geometry slots (eye, beak, tuft, accessory), the
  unlock model, the validation chokepoint, the picker. This is where the art
  cost lives and where the fun lives; it is independent of leaderboards and can
  land in pieces, one slot at a time.
- **S5 — leaderboards consume it.** The avatar is the identity primitive the
  leaderboard is built on, so it should land first and leaderboards should have
  no identity code of their own.

S0–S3 is a working feature: every student has a chickadee on their account page
and a handle in each course. S4 and S5 are the fun half and neither blocks the
other.

---

## What not to do

- **Do not derive the avatar or the handle from a username, email, student ID or
  name.** See decision 2. This is the one that turns the feature into a privacy
  defect.
- **Do not use a third-party avatar service.** DiceBear, Gravatar, boring-avatars
  and friends are all a student IP leak to a CDN on every page load — the same
  FIPPA/PIPEDA concern that put jszip, CodeMirror and the editor kernels under
  `Public/`. Gravatar additionally *is* the email-hash construction above.
- **Do not generate PNGs server-side.** That is an image pipeline, a cache, a
  storage decision and an invalidation bug, in exchange for nothing SVG does not
  already do better here.
- **Do not paste path data into a template or into page JS.** Guard S4 fails on
  it, and the reason it exists — fifteen copies of one trash can — applies with
  more force to a nine-part bird.
- **Do not put raw colour literals in the renderer.** The palette is tokens in
  `styles.css`, mirrored for dark mode.
- **Do not add an environment variable.** Standing rule. A leaderboard toggle is
  a course setting; a feature flag is a deploy, not a variable.
- **Do not re-derive from a seed on every render.** Appending one option would
  reshuffle everyone.

---

## Open questions

1. **Reroll.** Should a student be able to redraw their avatar at will? The
   handle is the identity, so a reroll costs nothing structurally — but a
   classmate who learned to recognize a bird loses that. Suggested answer: allow
   it, rate-limited, and keep the handle fixed across rerolls.
2. **Handle visibility to the student's own course peers.** Showing "you are
   Quiet Cedar" only to the student is the strict reading; showing handles in a
   discussion context would be a different feature with a different consent
   question.
3. **Opt-out.** Per-course instructor setting is clearly needed. Is a per-student
   opt-out of leaderboard listing also needed, and does an opted-out student still
   see their own rank?
4. **Where else avatars appear.** The account page and leaderboards are settled.
   Submission history is plausible; the instructor student tables are not — staff
   see real names there and an avatar beside a name is decoration with a cost.
5. **Drawing style.** The art is the one genuinely manual task, and S2 needs only
   about six shapes of it. Flat fills with no stroke, closer to the plush mascot,
   or stroked at the icon set's 24px weight? Flat fill is the better bet: it
   recolours cleanly, it reads at 24px where a stroke closes up, and it does not
   have to sit beside the Feather icons in the same visual role.
6. **How much bird.** A head-and-shoulders bust fills a 24px circle better than a
   full body and needs fewer parts, but the mascot's charm is that it is a
   sphere. Worth drawing both once before committing the sprite.
