// Tests/APITests/LTI/LTITestGradeService.swift
//
// A stand-in for an LMS's AGS and NRPS endpoints (docs/lti-1-3.md). It
// answers the token, line-item, score and membership requests an
// `LTIServiceClient` sends, records each one, and can be told to refuse the
// next score with a status.

import Foundation
import Vapor

@testable import APIServer

actor LTITestGradeService {
    static let tokenURL = "https://lms.example.edu/token"
    static let lineItemsURL = "https://lms.example.edu/api/lti/courses/7/line_items"
    static let createdLineItemURL = "https://lms.example.edu/api/lti/courses/7/line_items/42"
    static let membershipsURL = "https://lms.example.edu/api/lti/courses/7/names_and_roles"

    struct Recorded: Sendable {
        let method: HTTPMethod
        let url: String
        let authorization: String?
        let contentType: String?
        let body: String
    }

    private(set) var requests: [Recorded] = []
    /// Line items the LMS already has, as (resourceId, URL).
    private var existingItems: [(resourceID: String, url: String)] = []
    /// The status the next score POST answers with; 200 when nil.
    private var nextScoreStatus: HTTPStatus?
    private var tokenCount = 0
    private var members: [LTIMember] = []
    /// Members per membership page; nil sends one page.
    private var membersPerPage: Int?

    func setMembers(_ members: [LTIMember], perPage: Int? = nil) {
        self.members = members
        membersPerPage = perPage
    }

    func addExistingLineItem(resourceID: String, url: String) {
        existingItems.append((resourceID, url))
    }

    func refuseNextScore(with status: HTTPStatus) {
        nextScoreStatus = status
    }

    var scores: [LTIScore] {
        requests.filter { $0.url.hasSuffix("/scores") }.compactMap {
            try? JSONDecoder().decode(LTIScore.self, from: Data($0.body.utf8))
        }
    }

    var client: LTIServiceClient {
        LTIServiceClient { [self] request in await self.handle(request) }
    }

    func handle(_ request: ClientRequest) -> ClientResponse {
        let url = request.url.string
        requests.append(
            Recorded(
                method: request.method, url: url,
                authorization: request.headers.first(name: .authorization),
                contentType: request.headers.first(name: .contentType),
                body: request.body.map { String(buffer: $0) } ?? ""))

        if url == Self.tokenURL {
            tokenCount += 1
            return json(#"{"access_token":"token-\#(tokenCount)","token_type":"Bearer","expires_in":3600}"#)
        }
        if url.hasPrefix(Self.membershipsURL) {
            return membershipPage(url)
        }
        if url.hasSuffix("/scores") {
            let status = nextScoreStatus ?? .ok
            nextScoreStatus = nil
            return ClientResponse(status: status)
        }
        if request.method == .GET, url.hasPrefix(Self.lineItemsURL) {
            let items = existingItems.map { #"{"id":"\#($0.url)","resourceId":"\#($0.resourceID)","scoreMaximum":10}"# }
            return json("[" + items.joined(separator: ",") + "]")
        }
        if request.method == .POST, url == Self.lineItemsURL {
            return json(#"{"id":"\#(Self.createdLineItemURL)","scoreMaximum":10}"#)
        }
        return ClientResponse(status: .notFound)
    }

    /// One page of members; `?page=N` selects the page, and every page but
    /// the last links the next one.
    private func membershipPage(_ url: String) -> ClientResponse {
        let page = URLComponents(string: url)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 0
        let size = membersPerPage ?? max(members.count, 1)
        let slice = Array(members.dropFirst(page * size).prefix(size))
        let body =
            (try? JSONEncoder().encode(["members": slice])).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        var response = json(body)
        if (page + 1) * size < members.count {
            response.headers.add(name: .link, value: #"<\#(Self.membershipsURL)?page=\#(page + 1)>; rel="next""#)
        }
        return response
    }

    private func json(_ text: String) -> ClientResponse {
        ClientResponse(status: .ok, headers: ["Content-Type": "application/json"], body: ByteBuffer(string: text))
    }
}
