// Tests/APITests/Admin/DeployRequestRedundancyTests.swift
//
// The admin Deployment page reads back its own request files, which wait in
// requests/ until the deploy daemon's next poll, so that it neither invites
// nor writes a request that repeats what already waits. The daemon applies
// waiting files in order, so a repeat is judged against the LAST waiting
// request of its kind: after pause then resume, a second pause is new.

import Foundation
import Testing

@testable import APIServer

@Suite struct DeployRequestRedundancyTests {

    @Test(arguments: [
        DeployRequest.approve(version: "v0.6.0-rc.2"), .mode(.manual), .mode(.autonomous), .pause, .resume,
    ])
    func aRequestReadsBackFromTheBodyTheAppWrites(request: DeployRequest) {
        #expect(DeployRequest(body: request.body(user: "ada", requestedAt: Date())) == request)
    }

    @Test func aBodyThatNamesNoneOfTheFourIsNotARequest() {
        #expect(DeployRequest(body: ["request": "rollback"]) == nil)
        #expect(DeployRequest(body: ["request": "mode", "mode": "yolo"]) == nil)
        #expect(DeployRequest(body: ["request": "approve"]) == nil)
    }

    @Test func aModeRepeatsOnlyTheLastWaitingModeOrTheModeInForce() {
        let gated = DeployMode.gatedMinors
        #expect(DeployRequest.mode(gated).redundancy(waiting: [], modeInForce: gated) == .alreadyInForce)
        #expect(DeployRequest.mode(.manual).redundancy(waiting: [], modeInForce: gated) == nil)
        #expect(
            DeployRequest.mode(.manual).redundancy(waiting: [.mode(.manual)], modeInForce: gated) == .alreadyWaiting)
        // Manual, then back to gated, both waiting: manual again is a change.
        let back: [DeployRequest] = [.mode(.manual), .mode(gated)]
        #expect(DeployRequest.mode(.manual).redundancy(waiting: back, modeInForce: gated) == nil)
        #expect(DeployRequest.mode(gated).redundancy(waiting: back, modeInForce: gated) == .alreadyWaiting)
        #expect(DeployRequest.lastMode(in: back) == gated)
    }

    @Test func pauseAndResumeRepeatOnlyTheLastOfThePair() {
        #expect(DeployRequest.pause.redundancy(waiting: [.pause], modeInForce: .gatedMinors) == .alreadyWaiting)
        #expect(DeployRequest.pause.redundancy(waiting: [.pause, .resume], modeInForce: .gatedMinors) == nil)
        #expect(DeployRequest.resume.redundancy(waiting: [.pause, .mode(.manual)], modeInForce: .gatedMinors) == nil)
    }

    @Test func anApprovalRepeatsAnyWaitingApprovalOfTheSameVersion() {
        let waiting: [DeployRequest] = [.approve(version: "v0.6.0"), .mode(.manual)]
        #expect(
            DeployRequest.approve(version: "v0.6.0").redundancy(waiting: waiting, modeInForce: .manual)
                == .alreadyWaiting)
        #expect(DeployRequest.approve(version: "v0.6.1").redundancy(waiting: waiting, modeInForce: .manual) == nil)
    }

    @Test func waitingRequestsReadsOnlySmallRegularFilesInNameOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-req-\(UUID().uuidString)")
        let requests = root.appendingPathComponent("requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = DeployStateFolder(directory: root.path)
        try folder.write(.mode(.manual), user: "ada", at: Date(timeIntervalSince1970: 1))
        try folder.write(.pause, user: "ada", at: Date(timeIntervalSince1970: 2))
        try Data("not json".utf8).write(to: requests.appendingPathComponent("3-junk.json"))
        try Data(repeating: 0x20, count: 5000).write(to: requests.appendingPathComponent("4-big.json"))
        try FileManager.default.createSymbolicLink(
            at: requests.appendingPathComponent("5-link.json"),
            withDestinationURL: requests.appendingPathComponent("3-junk.json"))
        #expect(folder.waitingRequests() == [.mode(.manual), .pause])
    }
}
