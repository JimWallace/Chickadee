// APIServer/Utilities/LiveBoardETag.swift
//
// The ETag of a live board refresh, computed BEFORE the board is built, so a
// refresh whose board has not changed is answered 304 from one aggregate
// query (docs/live-board-cache.md). The HTML-hash ETag that
// `Response.pollFragment` computes saves bytes only: by the time it exists,
// the board has been built and rendered.
//
// The tag covers everything the fragment depends on:
//
// - the rows' fingerprint (`LiveBoardFingerprint`) and the activity's
//   manifest, which the caller folds into `fingerprint`,
// - who reads it and how: the viewer, staff or not, the full list or the
//   window, the lab group, present mode,
// - the live-session window's state, which changes the line above the rows,
// - the build, so a deploy that changes the markup is never answered 304,
// - the shared roster snapshot's digest, so a change to a ranked student's
//   handle or bird changes the tag,
// - a time bucket, which bounds how long any other change can go unseen: a
//   new title, a student who drops or changes role, an unranked viewer's own
//   card. At most `bucketSeconds`, after which every viewer builds once from
//   the shared snapshot.

import Core
import Crypto
import Foundation

enum LiveBoardETag {
    /// The longest a roster snapshot is kept, and the longest a change the
    /// fingerprint does not see can wait for a refresh to show it.
    static let bucketSeconds: Double = 30

    /// The parts of a request that change what the fragment shows: the
    /// viewer, whether they read as staff, and the query, which carries the
    /// fragment, the full-list switch, the lab group and present mode.
    struct Reader: Sendable, Equatable {
        let viewerID: UUID?
        let isStaff: Bool
        let query: String
    }

    /// The time bucket `now` falls in.
    static func bucket(at now: Date) -> Int {
        Int((now.timeIntervalSince1970 / bucketSeconds).rounded(.down))
    }

    static func tag(
        fingerprint: String, rosterDigest: String, reader: Reader, windowState: String, now: Date,
        build: String = ChickadeeVersion.current
    ) -> String {
        let parts = [
            fingerprint,
            rosterDigest,
            reader.viewerID?.uuidString ?? "-",
            reader.isStaff ? "staff" : "student",
            reader.query,
            windowState,
            build,
            String(bucket(at: now)),
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return "W/\"lb-\(lowercaseHex(digest.prefix(16)))\""
    }
}
