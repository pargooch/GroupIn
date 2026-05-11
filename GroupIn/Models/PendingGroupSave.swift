//
//  PendingGroupSave.swift
//  GroupIn
//
//  A `GroupSession` that's been created locally but hasn't yet been
//  durably persisted to CloudKit. AppState retries the save on the
//  same exponential-backoff schedule as `PendingEmit`; the persisted
//  queue lets a force-quit recover unflushed groups on next launch.
//
//  Why this exists at all: group creation should never block on
//  network. The user mints a GroupSession in-process, navigates to
//  the dashboard immediately, and the CloudKit upload happens in the
//  background. Without persistence we'd silently lose groups created
//  offline if the user kills the app before the network comes back.
//

import Foundation

struct PendingGroupSave: Codable, Hashable, Sendable {
    let group: GroupSession
    var retryCount: Int
    var nextRetryAt: Date

    /// Same 5→10→20→40→60s schedule as `PendingEmit`. Capped at 60s so
    /// a long outage doesn't push retries hours apart.
    static func backoff(after retryCount: Int) -> TimeInterval {
        let raw = 5.0 * pow(2.0, Double(retryCount))
        return min(60.0, raw)
    }

    /// Returns a copy with `retryCount` advanced and `nextRetryAt`
    /// pushed out by the corresponding backoff. Caller writes the
    /// new value back into the persisted queue.
    func bumpedRetry(now: Date = .now) -> PendingGroupSave {
        let next = retryCount + 1
        return PendingGroupSave(
            group: group,
            retryCount: next,
            nextRetryAt: now.addingTimeInterval(Self.backoff(after: next))
        )
    }
}
