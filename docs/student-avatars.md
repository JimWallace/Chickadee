# Student avatars — design note

**Status: not built.** This is a plan, not a description of behaviour. Nothing
in `Sources/` implements any of it yet. The account page still renders the
initials monogram described in `accountMonogram` / `.account-monogram`.

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

## Decisions

### 1. An avatar is a spec, not an image

`AvatarSpec` in `Core/` — `Codable`, `Sendable`, no Vapor — is a small struct of
enum slots:

| Slot | Options (first pass) | Notes |
|---|---|---|
| `cap` | 8 | cap + bib colour family; the strongest identity signal |
| `cheek` | 4 | white through cream |
| `flank` | 6 | belly and side tint |
| `wing` | 6 | plain, barred, tipped, speckled, edged, two-tone |
| `eye` | 5 | round, bright, sleepy, wide, wink |
| `beak` | 3 | short, stout, fine |
| `tuft` | 5 | smooth, tufted, cowlick, side-sweep, ruffled |
| `accessory` | 12 | including none — scarf, glasses, headphones, leaf, small hat |
| `backdrop` | 8 | flat tint or one simple shape |

≈8.3M combinations. The exact tables are a design exercise, not a commitment;
what matters is that the **stored artifact is the choice vector**, never
rendered bytes. Everything downstream follows from that: customization is
mutating a slot, an unlock is widening a slot's option set, rendering is a pure
function of the spec, and there is no image cache to invalidate, no storage
bucket, and nothing to regenerate when the art changes.

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
accessory and backdrop — about 28k combinations. A 300-student course draws
from that with roughly an 80% chance of a visible pair. Enforcing per-course
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

**Two sizes, different layer counts.** The account page gets the full stack; a
dense table gets a `micro` variant of four layers — body, cap, wing, accessory —
because 200 rows × 8 layers is 1,600 DOM nodes for a decoration. The variant is
a rendering choice over the same spec, not a second spec.

### 5. Customization and unlocks

Each option carries an unlock rule: `starter`, `achievement(id)`, or `staff`.
The initial draw uses starter options only; achievements widen the pool. Saving a
customization validates the chosen slots against the student's unlocked set at
one chokepoint — the same shape as `evaluateCourseWrite`, one function that
every door goes through.

Two consequences to accept up front:

- **Unlocks are account-global, not per-course.** A scarf earned in CS 135 is
  worn in CS 136. Per-course cosmetics would need per-course avatars, which
  decouples the avatar from the account page and loses the "that's me" property
  the whole feature exists for.
- **New options should arrive as unlockables, not as starters.** Adding a
  starter option is harmless once specs are materialized (decision 2), but a
  new unlockable is the version that gives someone something to earn.

The picker itself is one page section: the avatar at full size, one control per
slot, locked options shown locked rather than hidden — a student cannot chase a
badge they cannot see, which is the same note the achievements audit already
makes about unearned achievements.

---

## What it costs

- **Compute:** a draw is a few random bytes; a render is a table lookup and
  string building. Nothing measurable.
- **Storage:** one JSON column per user (~100 bytes), one text column per
  enrollment.
- **Bytes on the wire:** one sprite, inlined once per avatar-bearing page.
  Measure it when the art exists; if it is heavy, the micro variant can carry a
  reduced sprite.
- **DOM:** the reason the micro variant exists. Worth a number on a real
  leaderboard page before the full variant is used anywhere dense.

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

---

## Slice plan

Each slice is independently mergeable and independently useful.

- **S0 — the model.** `AvatarSpec`, the option tables, the draw, the handle
  generator and its word lists. All in `Core/`, all pure, all tested. A golden
  fixture pinning spec → layer list, so the renderer cannot drift from what a
  stored spec means. No UI, no schema.
- **S1 — persistence.** `avatar_spec` on the user row, `handle` on the
  enrollment row with UNIQUE(course, handle), first-use materialization with the
  `ensureSeed` race shape. Backfill is lazy by construction — nobody needs an
  avatar until a page renders one.
- **S2 — the account page.** The sprite, the `--avatar-*` tokens with dark
  mirrors, `_avatar.leaf`, and the monogram replaced. Owes a component-vocabulary
  entry in `docs/ui-design.md` (the vocabulary guard prices a new global class),
  a visual-regression baseline, and a run of the `ui-review` agent, which is
  unconditional for anything touching `Resources/Views/` or `styles.css`.
- **S3 — student-facing copy and compliance.** "In CS 135 you appear as Quiet
  Cedar", the export fields, the deletion path.
- **S4 — customization.** The unlock model, the validation chokepoint, the
  picker. Independent of leaderboards.
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
5. **Who draws the parts.** The art is the one genuinely manual task in the plan.
   Nine slots of stroked, flat-fill SVG at the icon set's weight, or a looser
   plush style closer to the mascot PNG?
