//
//  PendingMemberPublish.swift
//  GroupIn
//
//  A `User` (per-group membership) that's been committed locally but
//  hasn't yet been durably published to CloudKit. The same shape as
//  `PendingEmit` / `PendingGroupSave` — a persisted queue drained by
//  the same retry loop on the same exponential-backoff schedule.
//
//  Why this exists: create + join flows write the local member
//  immediately so the user sees themselves on the dashboard in
//  airplane mode, then hand the cloud-side publish to this queue.
//  Without persistence we'd silently lose the publish if the user
//  killed the app before the network returned — and the member
//  would appear to themselves but be invisible to anyone else once
//  CloudKit became reachable.
//

import Foundation

struct PendingMemberPublish: Codable, Hashable, Sendable {
    let user: User
    let groupID: UUID
    let inviteCode: String
    var retryCount: Int
    var nextRetryAt: Date

    /// Same 5→10→20→40→60s schedule as the other retry queues. Cap
    /// at 60s so a long outage doesn't space retries hours apart.
    static func backoff(after retryCount: Int) -> TimeInterval {
        let raw = 5.0 * pow(2.0, Double(retryCount))
        return min(60.0, raw)
    }

    func bumpedRetry(now: Date = .now) -> PendingMemberPublish {
        let next = retryCount + 1
        return PendingMemberPublish(
            user: user,
            groupID: groupID,
            inviteCode: inviteCode,
            retryCount: next,
            nextRetryAt: now.addingTimeInterval(Self.backoff(after: next))
        )
    }
}
