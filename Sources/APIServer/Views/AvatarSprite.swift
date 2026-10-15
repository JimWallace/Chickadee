// APIServer/Views/AvatarSprite.swift
//
// The avatar sprite (`Resources/Sprites/avatar-sprite.svg`): every drawn part of the generated
// student bird, as SVG symbols. `BaseLayout` renders this once on every
// signed-in page, because the nav shows the user's bird; `PresentLayout` has
// no nav, so the Present page renders it itself. The file is static and
// checked in, so it is output raw, as the layout outputs the icon sprite.

import Elementary

struct AvatarSprite: HTML {
    let page: PageRequestContext

    var body: some HTML {
        HTMLRaw(page.avatarSprite)
    }
}
