// APIServer/Views/AvatarSprite.swift
//
// The avatar sprite (`Resources/Sprites/avatar-sprite.svg`): every drawn part of the generated
// student chickadee, as SVG symbols. A page that shows an avatar renders this
// once. The file is static and checked in, so it is output raw, as the layout
// outputs the icon sprite.

import Elementary

struct AvatarSprite: HTML {
    let page: PageRequestContext

    var body: some HTML {
        HTMLRaw(page.avatarSprite)
    }
}
