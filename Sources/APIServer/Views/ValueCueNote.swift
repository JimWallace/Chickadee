// APIServer/Views/ValueCueNote.swift
//
// The note under a table of input values (#1996). The Global Inputs panel,
// each section's inputs and a family's Variables table render this one copy,
// so the wording and the link have one source. It renders hidden; each editor
// script shows it while its table has a row, because the cue it explains is
// drawn by that script.
//
// Keep in step with `_value-cue-note.leaf` while both exist.

import Elementary

struct ValueCueNote: HTML {
    var body: some HTML {
        p(.class("field-note field-note--muted js-value-cue-note"), .hidden) {
            "If a value has an amber border, read "
            a(
                .href(
                    "https://github.com/JimWallace/Chickadee/blob/main/docs/inputs.md#the-amber-cue-on-a-value"),
                .target(.blank), .rel("noopener noreferrer")
            ) {
                "the amber cue on a value "
                Icon("i-external")
                span(.class("visually-hidden")) { "(opens in a new tab)" }
            }
            "."
        }
    }
}
