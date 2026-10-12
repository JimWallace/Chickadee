// APIServer/Views/Icon.swift
//
// One icon from the inline sprite (`Resources/Sprites/icons.svg`).

import Elementary

/// One icon from the sprite, as `<svg class="icon" aria-hidden="true">`.
struct Icon: HTML {
    let symbol: String

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some HTML {
        SVG.svg(.class("icon"), .ariaHidden) {
            SVG.use(.href("#\(symbol)")) {}
        }
    }
}
