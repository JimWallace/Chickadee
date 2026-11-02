// APIServer/Routes/Web/AccountRoutes+Found.swift
//
// A found wardrobe item (docs/student-wardrobe.md, "Found items").
//
//   POST /account/wardrobe/found   item=border.quantumcats → {"granted": true}
//
// `Public/quantum-cats-egg.js` posts here when a student enters the Konami
// code, then shows the banner the layout renders hidden. `granted` is true
// only for the request that stored the item, so the banner says "new ring"
// once.
//
// Nothing checks that the student really entered the code: the item is a
// cosmetic, and anyone who reads the script can post the form. That is
// accepted; the CSRF token still keeps another site from granting it.

import Core
import Vapor

extension AccountRoutes {

    struct FoundItemForm: Content {
        var item: String
    }

    struct FoundItemResponse: Content {
        /// True when this request stored the item.
        let granted: Bool
    }

    @Sendable
    func grantFoundItem(req: Request) async throws -> FoundItemResponse {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(FoundItemForm.self)
        guard let item = WardrobeItem(rawValue: form.item), item.isFound else {
            throw AppError.invalidParameter(name: "item", reason: "\(form.item) is not a found item.")
        }
        let granted = try await WardrobeUnlockStore.grantFound(item, for: user.requireID(), on: req.db)
        return FoundItemResponse(granted: granted)
    }
}
