// APIServer/Views/Icon.swift
//
// One icon from the inline sprite (`_icons.leaf`).

import Elementary

/// One icon from the sprite, as `<svg class="icon" aria-hidden="true">`.
struct Icon: HTML {
    let symbol: String

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some HTML {
        svg(.class("icon"), .ariaHidden) {
            SVGUse(.href("#\(symbol)")) {}
        }
    }
}
