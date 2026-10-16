// APIServer/Views/NotebookBootPanel.swift
//
// The panel over the notebook editor while it starts (design frame 18e): the
// viewer's bird pecking at seeds, three steps, and one line on how long it
// takes. `NotebookBody` renders it over `#jl-frame`. `Public/notebook-boot.js`
// moves it through the steps from the kernel phases that
// `jl-kernel-diagnostics.js` posts, and fades it out when the kernel is idle.
// The failure panel replaces it (`notebook-preflight.js`).
//
// The ids, the `data-boot-step` names and the `js-` class are read by
// `notebook-boot.js` and `notebook-preflight.js`.

import Core
import Elementary

struct NotebookBootPanel: HTML {
    /// The declared language when it has an editor kernel, else nil.
    let kernelLanguage: String?
    /// The viewer's bird with the curious face, or nil when they have none.
    let bird: AvatarPresentation?

    /// How the panel names what starts: "Python", or "the kernel" when the
    /// assignment declares no language with an editor kernel.
    private var runtimeName: String { kernelLanguage ?? "the kernel" }

    var body: some HTML {
        section(
            .id("nb-boot"), .class("nb-boot"), .data("phase", value: "boot_start"),
            .custom(name: "aria-labelledby", value: "nb-boot-title")
        ) {
            if let bird {
                // Decorative: the bird says nothing that the text does not.
                div(.class("nb-boot-bird"), .ariaHidden) {
                    Avatar(avatar: bird)
                    div(.class("nb-boot-seeds")) {
                        span {}
                        span {}
                        span {}
                    }
                }
            }
            h2(.class("nb-boot-title"), .id("nb-boot-title")) {
                "Starting \(kernelLanguage ?? "the notebook") in your browser"
            }
            ol(.class("nb-boot-steps")) {
                step("editor", "Load the editor", state: "active")
                step("kernel", "Download and start \(runtimeName)", state: "pending")
                step("notebook", "Open your notebook", state: "pending")
            }
            div(.class("nb-boot-bar"), .ariaHidden) {}
            p(.class("nb-boot-note")) {
                "This usually takes about 10 seconds. Next time is faster, "
                    + "because your browser keeps the download."
            }
            p(.class("visually-hidden js-nb-boot-live"), .custom(name: "aria-live", value: "polite")) {}
        }
    }

    private func step(_ name: String, _ text: String, state: String) -> some HTML {
        li(.data("boot-step", value: name), .data("state", value: state)) { text }
    }
}
