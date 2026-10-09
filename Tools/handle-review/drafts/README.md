# Draft handle lists (Fall 2026 review)

These files are the data for a planned redesign of the class handle. No code
reads them yet: `Sources/Core/AvatarHandle.swift` still draws from its own
adjective and noun lists. The design is in `docs/student-avatars.md` §3,
"Planned redesign: three schemes".

## Files

| File | What it holds |
|---|---|
| `scientists-*.psv` | Scientists, engineers and mathematicians for the "disposition + scientist" scheme |
| `removed-for-balance.psv` | Men from Europe and North America, removed to balance the list. Do not add them back without a balance review |
| `words.txt` | The dispositions, science nouns, agents, and the parts of the compound words |

A `.psv` line has eight fields, separated by `|`:

```
handle|full name|field|born|died|region|gender|note
```

- `handle` is the name in the handle: one or two words.
- `~` before a year means that the year is approximate. A negative year is BCE.
- An empty `died` field means that the person is alive.
- `gender` is `F`, `M`, or `M+F` for an entry that names two people with the
  same surname.

## Selection rules

- The person is known mainly for the work, and has no major scandal.
- The person has died, or is alive and has a major honour: for example a Nobel
  Prize, Fields Medal, Abel Prize, Turing Award, Wolf Prize, Breakthrough
  Prize, L'Oréal-UNESCO Award or MacArthur Fellowship.
- The handle is the name the person is known by, in one or two words, with
  diacritics and real hyphens. Apostrophes are not allowed.
- The whole list has at least 40% women and at most 35% people from Europe.
- The word lists pass the data in `../data/`. A disposition may be a trait,
  but only a positive one about character, never about mood, the body, the
  mind or intelligence.

## Before each term

Check again that every living person on the list is alive and has no new
scandal. Remove a name at once if there is a problem.

## Work that remains

1. `AvatarHandle`: a type for the three schemes, with equal weights. The draw
   prefers a scientist that nobody in the course uses yet. The shape rule
   accepts one to three words, non-ASCII letters, hyphens and internal
   capitals. All text is stored in Unicode NFC form.
2. `review.mjs`: read the three schemes. Split `traits.txt` into banned traits
   and positive dispositions. Check compound words for unwanted substrings.
   Check the two balance targets.
3. `AvatarHandleTests`: change the tests for the schemes (the maintainer
   approved these changes) and add tests for the new rules.
4. `docs/student-avatars.md` §3: replace the planned-redesign note with the
   final rules.
