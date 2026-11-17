// Tests/APITests/Assignments/ContentAttachmentStoreErrorReasonTests.swift
//
// `ContentAttachmentStore.StoreError.reason` is the text that the web form
// and the MCP tools show when an attachment upload is refused. The route
// tests check that each error is thrown. These check what it says.

import Testing

@testable import APIServer

@Suite struct ContentAttachmentStoreErrorReasonTests {

    @Test func unsafeNameQuotesTheName() {
        let reason = ContentAttachmentStore.StoreError.unsafeName("../etc/passwd").reason
        #expect(reason == "File name \"../etc/passwd\" is not a valid bare filename.")
    }

    @Test func disallowedTypeListsEveryAllowedExtensionInOrder() {
        let reason = ContentAttachmentStore.StoreError.disallowedType("exe").reason
        let list = ContentAttachmentStore.allowedExtensions.sorted().joined(separator: ", ")
        #expect(reason == "File type \".exe\" is not allowed. Allowed: \(list).")
        #expect(reason.contains("csv, docx, gif"))
    }

    @Test func tooLargeStatesTheLimitInMegabytes() {
        let reason = ContentAttachmentStore.StoreError.tooLarge(name: "big.pdf").reason
        #expect(reason == "File \"big.pdf\" exceeds the 25 MB limit.")
    }
}
