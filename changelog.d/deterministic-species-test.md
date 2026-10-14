### Fixed

- **`AccountSpeciesPickerTests` no longer fails at random.** A new test user's
  first bird is a seeded draw, and the draw can pick a hat that hides the
  crest the test expects. About one run in seven failed. The test now sets
  the accessory itself and checks the exact crest symbol. A new test checks
  that a hat hides the crest.
