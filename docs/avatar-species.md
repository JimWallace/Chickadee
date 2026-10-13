# Avatar species — design note

**Status: proposed.** Nothing here has shipped. This note continues
[student-avatars.md](student-avatars.md) and
[student-wardrobe.md](student-wardrobe.md). Read decisions 1, 2 and 7 there
first: the spec is stored and drawn once, the art is a sprite of flat closed
paths, and the sizes decide what reads.

| Part | Status |
|---|---|
| Prototype render of five species on the current body | done, see "What the prototype showed" |
| `AvatarSpecies` slot and per-species colourways | proposed |
| Sprite symbols for cardinal, robin, blue jay, starling | proposed |
| Species in the account-page picker | proposed |
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

6. **The wing mark needs its own token.** Today `.av-wing-mark` and `.av-brow`
   are the fixed body cream. On a starling the body is dark, so a body-coloured
   mark disappears, and on a blue jay the natural bars are black. A colourway
   therefore carries a `mark` tone as well as the others. The same token draws
   the brow, so the `curious` brow stays visible on every species.

7. **The beak rule still applies, per species.** The beak must be the lightest
   of the tones it sits on (student-avatars.md, decision 7). A natural house
   sparrow has a dark beak on a black bib and disappears in flat vector. Each
   species sets its own beak tone with that rule, not from a field guide.

8. **Beak shape stays fixed.** The `startled` expression redraws the beak as an
   open mouth with fixed geometry. A per-species beak shape would fork every
   expression that touches the beak. Beak colour varies; beak shape does not.

The prototype files are not in the repository. Regenerate them when the
first sprite symbols exist, with `Tools/avatar-preview/preview.mjs`, which
must then learn a species row.

---

## Decisions

### 1. Species is a slot, drawn once, and absent means chickadee

```swift
public enum AvatarSpecies: String, CaseIterable, Codable, Sendable {
    case chickadee, cardinal, robin, bluejay, starling
}
```

`AvatarSpec.species` is decoded with `decodeIfPresent`, and an absent key is
`.chickadee`. Every stored bird was drawn as a chickadee, so the default is
the true historical value and not a guess. **There is no migration and no
random fill.** The `FillLateAvatarAxes` precedent filled empty tuft and tilt
slots because an unfilled slot split a class into two visible cohorts. A
random species fill would turn a known bird into a different bird, which is
the reshuffle that decision 2 forbids. The cohort split that remains, old
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
| cardinal | scarlet, crimson, fawn | fawn is the female's buff with a red crest and wing |
| robin | brick, apricot, copper | the breast varies; the hood stays grey-brown |
| bluejay | azure, cobalt, powder | the mark tone is dark: a jay's bars are black |
| starling | emerald, violet, bronze | body lifted above the dark backdrops (finding 4) |

Colourway names are unique across the enum, because the enum is one. The
chickadee's `rust` is already taken, so the robin's breast is `brick`, not
rust.

A spec is valid only when `cap` is in `species.colourways`. The draw picks a
species, then a colourway from that species. The customization chokepoint
refuses a pair that does not match with a new error case, and never changes
one slot without the other.

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

`av-plumage` becomes `av-plumage-<species>`. Each symbol draws the body
circle, the species' head and face shapes, the two eye discs and the closed
beak, with the shared classes only. A crested species also gets
`av-crest-<species>`, which the presentation uses in place of `av-tuft-none`
(finding 5). The layer order does not change.

The three sprite rules hold. Every new shape is a closed path computed
against the body circle, with no clip-path, mask, filter or gradient. The
mirrored chestnut patches in the sparrow prototype use the same mirroring
group as the wings.

`AvatarPresentation.layerRefs` gets a `plumageSymbolRef`. The drift tests
that pin the literal plumage symbol and the per-case symbol sets must learn
the species dimension, in both directions, so a species without art and art
without a species both fail. Those are changes to existing tests, so they
need the maintainer's agreement first.

### 5. Species is chosen on the account page, like the backdrop

`AvatarCustomizableSlot` gains `species`, and the picker gets a **Bird**
group beside Backdrop and Border. Choosing a species shows that species'
colourways as a second group, and Save posts both. The chokepoint validates
the pair (decision 2).

Why a choice and not only a draw: it closes the cohort split from decision 1,
it lets a student who wants the mascot keep it, and the wardrobe is lateral,
so a cardinal is different from a chickadee and not better. The handle stays
the identity. A classmate who recognized a bird by species loses that on a
change, which is the reroll question already open in student-avatars.md. The
suggested answer there holds here: allow it, keep the handle fixed.

The live preview in `avatar-picker.js` sets custom properties and points one
`use` at a symbol. A species change moves nine properties and two symbols
(plumage and crest). That is the same mechanism, more of it, and still no
colour in JavaScript.

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
| A0 | `AvatarSpecies`, the colourway rule, the six-token palette, the four inline properties, the drift tests, the chickadee only | proposed |
| A1 | Cardinal, robin, blue jay and starling: sprite symbols, crests, colourways, `preview.mjs` species row, a render looked at | proposed |
| A2 | The Bird group in the picker, with its colourway group and live preview | proposed |
| A3 | A second set from the candidates, each rendered first | later |

A0 ships no visible change. It is the model, the palette and the guards, so
A1 is only art and A2 is only a form.

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
