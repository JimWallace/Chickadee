# Avatar species — design note

**Status: the first set is built, and a student can choose.** Slices A0 and
A1 shipped together: the model, the six-token palette, the sprite art for the
cardinal, the robin, the blue jay and the starling, and the guards. A2, the
Species group in the account-page picker, shipped next. The second set (A3)
and the trait weights are next. This note continues
[student-avatars.md](student-avatars.md) and
[student-wardrobe.md](student-wardrobe.md). Read decisions 1, 2 and 7 there
first: the spec is stored and drawn once, the art is a sprite of flat closed
paths, and the sizes decide what reads.

| Part | Status |
|---|---|
| Prototype render of five species on the current body | done, see "What the prototype showed" |
| `AvatarSpecies`, derived from the colourway, and per-species colourways | shipped |
| Sprite symbols for cardinal, robin, blue jay, starling | shipped |
| Species in the account-page picker | shipped (A2) |
| The second set: goldfinch, blackbird, waxwing, junco, sparrow redrawn | next (A3), each rendered first |
| House sparrow | needs a redraw, see finding 2 |

---

## The idea

Today every avatar is a black-capped chickadee. The cap colour, the wing
pattern, the expression, the accessory, the backdrop, the tuft and the tilt
vary. The species does not. The design chose that on purpose: the markings
are the species read, and a free variation of them would make "twelve
different birds".

The proposal keeps that argument and moves it one level up. **Each species is
its own generator, and all species share one skeleton.** A cardinal, a robin,
a blue jay and a starling each get their own plumage art and their own small
set of colourways. Everything that is not plumage stays shared: the body
circle, the eye discs, the beak, the six wing patterns, the nine expressions,
the accessories, the tufts, the backdrops, the rings and the tilt.

What makes the birds one family then changes. Today it is the species. After
the change it is the drawing: one silhouette, one eye geometry, one wing
outline, one set of clothes. The prototype shows that this is enough. A row
of mixed birds reads as one set, not as clip art.

**The cost to name once.** The avatars were meant to carry the Chickadee
mascot onto pages where the student's name does not appear. After this change
only some birds do that. The mascot stays in the logo and the product name.
The maintainer accepts this trade.

---

## What the prototype showed

The prototype draws five species on the real body circle, with the real
sprite and the real stylesheet, and renders them at 80, 48, 36 and 24 px.
It is a looking-glass, not repository code. The findings:

1. **The shared skeleton holds.** Every expression, every wing pattern, every
   accessory and every tuft renders on every species with no change to its
   art. The lids that `sleepy` and `keen` draw in the cap colour sit correctly
   on a robin's hood and on a cardinal's crown. Glasses sit over a cardinal's
   mask. The headband, the bow tie and the scarf need nothing. This is the
   result that makes the whole proposal cheap: the species costs one plumage
   symbol and three colourways, and nothing else.

2. **The house sparrow does not separate from the chickadee.** At 36 px,
   beside a chickadee, it reads as a brown chickadee. The two share a
   topology: a cap, a dark bib, a pale cheek. Colour alone does not carry a
   species read when the shapes are the same. Either drop the sparrow from the
   first set, or redraw it as a song sparrow (a streaked breast with a central
   spot, no bib) and render it again before it goes in.

3. **Species improves recognition at roster size.** At 24 px the current
   design admits that the picture is "recognition, not identification". In
   the mixed roster the red, orange, blue and dark birds separate at 24 px
   better than two chickadees do at 36 px. Colour mass is what reads at small
   sizes, and species is colour mass.

4. **A dark bird vanishes on a dark backdrop.** The bird's own colours do not
   change between themes (student-avatars.md, decision 7). The starling as
   first drawn is a dark body on a dark cap, and on the dark-mode backdrops it
   became a dark disc with two eyes. The ink chickadee has the same cap and
   survives because its body is cream. **Rule:** every colourway must keep a
   clear lightness step between its body and the darkest dark-mode backdrop.
   A starling therefore needs a lifted body tone, or a pale throat, not the
   natural near-black.

5. **A fixed crest and the tuft axis fight.** The cardinal and the blue jay
   have a crest as a species feature. Drawn inside the plumage, it collides
   with the cowlick, crest, pair and swoop tufts, and a beanie leaves the
   crest's tip showing beside the hat, which is the gradcap problem again.
   **Rule:** a species crest is drawn in the TUFT layer as that species'
   `none` tuft, and `hidesTuft` hides it with the others. The four tuft shapes
   remain available on a crested species, where they read as crest variants.
   The crest is drawn in the WING tone, not the cap tone: on the fawn the cap
   is buff and the wing is red, which is the female cardinal, and on every
   crested bird the crest then stands off the head.

6. **The wing mark needs its own token.** Today `.av-wing-mark` and `.av-brow`
   are the fixed body cream. On a starling the body is dark, so a body-coloured
   mark disappears, and on a blue jay the natural bars are black. A colourway
   therefore carries a `mark` tone as well as the others. The same token draws
   the brow, so the `curious` brow stays visible on every species. The
   stylesheet's eye-disc rule, every cap at least 3:1 against white, holds for
   every colourway, and a test asserts it: the first fawn and powder caps
   failed it and were darkened.

7. **The beak rule still applies, per species, as a contrast rule.** The
   beak must contrast clearly with the tone it sits on (student-avatars.md,
   decision 7, where that meant "lightest", because a chickadee's beak sits
   on a dark bib). A natural house sparrow has a dark beak on a black bib and
   disappears in flat vector. The cardinal's beak sits on its black mask, so
   it is orange; the blue jay's sits on a white face, so it is dark. Each
   species sets its beak tone by that rule, not from a field guide.

8. **Beak shape stays fixed.** The `startled` expression redraws the beak as an
   open mouth with fixed geometry. A per-species beak shape would fork every
   expression that touches the beak. Beak colour varies; beak shape does not.

The prototype files are not in the repository. `Tools/avatar-preview/preview.mjs`
now opens with the species rows: every colourway, the species at 36 px beside
each other, every expression and hat on every species, and every backdrop. It
reads the species and their colourways out of `Sources/Core/AvatarSpecies.swift`.
Run it before a new species goes in.

---

## Decisions

### 1. Species is derived from the colourway, and nothing new is stored

```swift
public enum AvatarSpecies: String, CaseIterable, Codable, Sendable {
    case chickadee, cardinal, robin, bluejay, starling
}
```

The note first proposed a stored `species` key with `decodeIfPresent`.
Building it showed a simpler model. The colourways **partition** the `cap`
enum: each belongs to exactly one species (`AvatarSpecies.colourways`, and a
test asserts the partition). So `AvatarSpec.species` is a computed property,
`AvatarSpecies.of(cap)`, and the spec gains no key. A spec stored before any
species but the chickadee existed names a chickadee colourway and IS a
chickadee. There is nothing to decode, nothing to fill, no pair of slots that
can disagree, and no migration. The customization chokepoint (A2) validates
one slot, the colourway, and the species follows.

**There is no random fill.** The `FillLateAvatarAxes` precedent filled empty
tuft and tilt slots because an unfilled slot split a class into two visible
cohorts. A species fill would turn a known bird into a different bird, which
is the reshuffle that decision 2 forbids. The cohort split that remains, old
accounts are chickadees and new ones are mixed, is closed by the picker
(decision 5).

Append only. A species is never renamed, reordered or removed.

### 2. A colourway belongs to a species

The `cap` slot stays, under its stored key, and becomes the colourway slot.
`AvatarCap` gains cases, appended, and each species names the cases that are
valid for it:

| Species | Colourways | Notes |
|---|---|---|
| chickadee | the eight that exist | unchanged, so no stored bird changes |
| cardinal | scarlet, crimson, fawn | fawn is the female's buff with a browner crown, and a red crest and wing |
| robin | brick, apricot, copper | the breast varies; the hood stays grey-brown |
| bluejay | azure, cobalt, powder | the mark tone is dark: a jay's bars are black |
| starling | emerald, violet, bronze | body lifted above the dark backdrops (finding 4) |

Colourway names are unique across the enum, because the enum is one. The
chickadee's `rust` is already taken, so the robin's breast is `brick`, not
rust.

The draw picks a species, each equally likely, then a colourway from that
species. A draw over every colourway at once would make a chickadee eight
times as likely as a cardinal. Because the species is derived, there is no
pair to validate: the picker (A2) offers colourways grouped by species, and
choosing one chooses both.

The chickadee keeps eight colourways, four of which are frankly artificial.
The new species get three natural ones each. That is deliberate. The
chickadee's artificial colours were safe because the markings carried the
species. For a cardinal, the colour IS the species, so a plum cardinal is not
a cardinal.

### 3. A colourway is six tokens

Today a cap family is a pair, `--avatar-<cap>-cap` and `--avatar-<cap>-wing`,
and body, bib, beak and mark are fixed tokens. A colourway becomes six:

```text
--avatar-<colourway>-cap
--avatar-<colourway>-wing
--avatar-<colourway>-body
--avatar-<colourway>-bib
--avatar-<colourway>-beak
--avatar-<colourway>-mark
```

The eight chickadee colourways gain the four new tokens with the values the
fixed tokens hold today, so no chickadee changes. `AvatarPresentation` emits
four new inline properties, `--av-body`, `--av-bib`, `--av-beak` and
`--av-mark`, beside the five it emits now. The plumage classes read them
instead of the fixed tokens. The four names join the inline-custom-property
allowlist in `check-styles.sh` for the reason the first five did: each
carries a value that varies per student.

Only the backdrops keep dark-mode mirrors. The bird is the same bird in both
themes, and finding 4 is the constraint that makes that possible.

### 4. One plumage symbol per species, and the crest in the tuft layer

`av-plumage` became `av-plumage-<species>`. Each symbol draws the body
circle, the species' head and face shapes, the two eye discs and the closed
beak, with the shared classes only. A crested species also has
`av-crest-<species>`, which the presentation uses in place of `av-tuft-none`
(finding 5). The layer order did not change. `AvatarSpeciesTests` asserts
that every plumage symbol contains the four skeleton elements verbatim, so a
species cannot move an eye.

The three sprite rules hold. Every new shape is a closed path computed
against the body circle, with no clip-path, mask, filter or gradient. The
mirrored chestnut patches in the sparrow prototype use the same mirroring
group as the wings.

`AvatarPresentation.layerRefs` carries a `plumageSymbolRef`. The drift
tests pin the plumage and crest symbol sets against `AvatarSpecies` in both
directions, so a species without art and art without a species both fail,
and a body tone that drops within 1.7 of the darkest dark-mode backdrop
fails too (finding 4).

### 5. Species is chosen on the account page, like the backdrop

`AvatarCustomizableSlot` gained `cap`, the colourway under its stored key,
and the picker got a **Species** group above Backdrop and Border: one row per
species, every colourway as a radio, each drawn as the student's own bird in
that colourway at the roster size. Choosing a colourway chooses the species,
so Save posts one value and the chokepoint validates one slot (decision 1).

Why a choice and not only a draw: it closes the cohort split from decision 1,
it lets a student who wants the mascot keep it, and the wardrobe is lateral,
so a cardinal is different from a chickadee and not better. The handle stays
the identity. A classmate who recognized a bird by species loses that on a
change, which is the reroll question already open in student-avatars.md. The
suggested answer there holds here: allow it, keep the handle fixed.

The live preview in `avatar-picker.js` sets custom properties and points
`use` elements at symbols. A colourway change moves six properties and two
layers (the plumage, and the tuft or crest). Each radio carries them as data
attributes computed by `AvatarPresentation`, so the script holds no palette
and no species, and the preview draws exactly what a save would. The ring
samples inherit the cap, accent and backdrop from the form, so the two-tone
ring follows a colourway change before it is saved.

### 6. What does not change

- Handles. No scheme names a bird, so nothing moves.
- The six wings, the nine expressions, the accessories, the tufts, the
  backdrops, the rings, the staff ring and the tilt. All shared, all unchanged.
- The seven `use` elements per bird. A crest replaces the tuft; it does not add
  a layer.
- The export and deletion paths. The species is one more key in the spec,
  which `profile.json` already carries.
- No environment variable.

---

## Counts

The first-use draw today picks from 1,382,400 birds. With four new species
of three colourways each, the colourway axis goes from 8 to 20, and the draw
picks from 3,456,000. The number is for the changelog, not the design: as
before, it counts settings and not birds a person can tell apart. What
changes for a person is finding 3, and that is the number that matters.

---

## Next: trait weights, and which traits belong to a species

Two questions the maintainer raised while the first set landed. Neither is
built. Both change only the draw, so a stored bird never changes.

**Weights.** The draw today is uniform in every slot except the species,
which it picks first so that a class is as mixed as it can be. A uniform
tilt means one bird in three is askew, which reads as a crowd leaning, not
as a few characters. A slot can carry weights the way `HandleScheme.weight`
does: most birds upright, a few leaning. The same question applies to the
tuft (`none` more often), the accessory (`none` more often) and the three
unlockable expressions (already weight zero in the starter draw). The
species stays uniform: diversity in one class is the point.

**Species traits against universal traits.** A crest belongs to the cardinal
and the blue jay. Today the four tuft shapes are still drawn on every
species, and on a crested bird they read as crest variants. The alternative
is that some slots are per species (a tuft only where the real bird has
one, a crest shape only on crested birds, a breast patch only on the robin)
and others are universal (tilt, expression, accessory, backdrop, ring). The
cost is that `combinationCount` becomes a sum over species instead of a
product, and the draw picks the species-scoped slots after the species, the
way it already picks the colourway. The benefit is that every species gets
its own silhouette vocabulary instead of a chickadee's.

## Candidates for a second set

Each needs a prototype render before a decision, by finding 2.

| Species | The read | Risk |
|---|---|---|
| American goldfinch | yellow body, black forehead and wings | the black cap is the chickadee topology; the yellow may carry it |
| red-winged blackbird | black body, red and yellow epaulet | the dark body meets finding 4 |
| cedar waxwing | crest, black mask, yellow tail tip | the crest and mask are the cardinal topology in fawn |
| dark-eyed junco | dark hood, white belly | the robin topology without the orange |
| house or song sparrow | redrawn per finding 2 | a second render decides |
| mourning dove | plain, soft grey-brown | may read as a plain chickadee |

---

## Slice plan

| Slice | Content | Status |
|---|---|---|
| A0 | `AvatarSpecies`, the colourway rule, the six-token palette, the four inline properties, the drift tests | shipped |
| A1 | Cardinal, robin, blue jay and starling: sprite symbols, crests, colourways, `preview.mjs` species rows, a render looked at | shipped |
| A2 | The Species group in the picker, every colourway by species, with the live preview | shipped |
| A3 | A second set from the candidates, each rendered first | next |

A0 and A1 shipped as one change. From the day it is live, a new student's
first-use draw is one of the five species, and every stored bird is the
chickadee it was.

---

## What not to do

- **Do not fill the species of a stored bird.** A chickadee stays a chickadee
  until its student chooses otherwise.
- **Do not reuse a colourway name across species.** The enum is one; a stored
  raw value must mean one thing.
- **Do not vary the beak shape, the eye positions or the body circle per
  species.** Every expression and every accessory is drawn against them.
- **Do not ship a species that has not been rendered beside a chickadee at
  36 px.** Finding 2 is the reason.
- **Do not let a colourway's body approach the dark backdrops.** Finding 4 is
  the reason.
- **Do not put a flag, a uniform or a real-world signifier in a colourway.**
  Species colours are bird-plausible or frankly artificial, as before.
