### Changed

- **Each auto-compute warning title is one phrase, and the advice is in a doc.** The titles for a call timeout, a `None` result and a value that has no JSON form had two sentences each. Each is now one phrase, for example "Solution call did not return within 5 seconds". What to do about each warning is in the new `docs/auto-compute.md`, and a note under the cases table links it, because a touch screen does not show a title. A JS test holds every auto-compute title to one phrase of at most 20 words (#1991).
