### Fixed

- **The pattern-family editor knows which language it is editing.**
  `Public/pattern-family-editor.js` contained the string "language" zero times:
  it validated Python identifiers, accepted `True`/`False`/`None`, rewrote
  pasted values by Python's rules, and named Python in its optional-argument
  placeholder — on R, Lua, Octave, C++ and Racket assignments alike, while the
  server rendered the same family correctly in those languages. An R author who
  typed the boolean true got the *string* instead, silently, in a value that
  decides marks. Both authoring pages now seed `#assignment-language-seed` from
  the new `AuthoringLanguageFacts`, whose scalar spellings are computed by
  `JSONValue.literal(_:)` — the same call that renders the real generated test,
  so the editor cannot drift from what will actually be produced. Python's facts
  reproduce the previous hardcoded constants exactly, so Python assignments are
  unchanged.
- **C++ is offered no null token.** Its `literal(.null)` is the poison
  identifier the renderer emits so a leak becomes a compile error; the editor no
  longer offers that as something to type, matching the save-time refusal.
