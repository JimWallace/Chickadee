// APIServer/Middleware/AsyncMiddlewareGroup.swift
//
// Runs a list of AsyncMiddleware as one layer of Vapor's chain (#2905).
//
// Vapor 4 runs every AsyncMiddleware it is given through a bridge to its
// EventLoopFuture chain: a new Task per layer, and a hop back to the event
// loop between layers. A profile of the release server put those hand-offs at
// about 38% of a trivial request's CPU, about 47 µs per layer, and a status
// poll passed 27 of them. Grouping the layers keeps each middleware exactly as
// it is and calls the members' async `respond` directly, one after another,
// inside one Task.
//
// Vapor 5's chain is async throughout (docs/vapor-5-migration.md); there the
// groups become a plain middleware list again.

import Vapor

/// Runs `members` in order as one middleware: every member sees every request
/// in the listed order, can short-circuit or throw, and sees the response on
/// the way back, exactly as if each were registered on its own.
struct AsyncMiddlewareGroup: AsyncMiddleware {
    let members: [any AsyncMiddleware]

    init(_ members: [any AsyncMiddleware]) {
        self.members = members
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        try await respond(to: request, from: members.startIndex, chainingTo: next)
    }

    /// Runs the member at `index`, with the rest of the group and then `next`
    /// as the responder it chains to.
    private func respond(
        to request: Request, from index: Int, chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard index < members.endIndex else {
            return try await next.respond(to: request)
        }
        let rest = AsyncBasicResponder { request in
            try await respond(to: request, from: index + 1, chainingTo: next)
        }
        return try await members[index].respond(to: request, chainingTo: rest)
    }
}
